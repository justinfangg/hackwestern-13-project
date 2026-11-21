import Foundation
import Observation
import CoreGraphics
import FogCore
import FogLocation
import FogNetworking

/// Drives the Daily Quest flow: geofence → capture → verify → sticker (PRD Q-5 to Q-12).
/// Jonathan's quest sheet renders `state` and calls `capture(_:)` / `retry()`; no logic lives in the view.
@MainActor
@Observable
public final class QuestCaptureModel {
    public enum State: Equatable {
        /// No quest loaded (or none today).
        case noQuest
        /// Too far away; camera stays locked (Q-5).
        case locked
        /// Within range; camera unlocked.
        case ready
        /// Photo taken; extracting sticker + waiting for AI verification.
        case verifying
        /// Verified; sticker collected (Q-8).
        case success(Sticker)
        /// Not verified; show the model's reason and allow a retry (Q-12).
        case rejected(reason: String, attemptsRemaining: Int)
        /// Used all 5 attempts today.
        case outOfAttempts
        /// Network or server problem; retry allowed.
        case error(String)
    }

    public private(set) var state: State = .noQuest
    public private(set) var quest: Quest?
    /// Live distance to the quest target in metres, for "420 m" on the quest card.
    public private(set) var distanceToTarget: Double?
    /// True when the camera may be used (Q-5).
    public var canCapture: Bool { state == .ready }

    /// Unlock radius in metres (PRD Q-5).
    public var unlockRadius: Double = 40
    /// Re-lock only beyond this, so the button doesn't flicker at the edge.
    public var relockRadius: Double = 50
    /// Minimum model confidence to accept (PRD §10.5).
    public var minimumConfidence: Double = 0.7

    /// Called once per successful find (FogKit wires this to Quest Reveal, expedition, sync).
    @ObservationIgnored public var onSuccess: ((Sticker, Quest) -> Void)?

    @ObservationIgnored public var verifier: QuestVerifying
    @ObservationIgnored private let extractor: StickerExtracting
    @ObservationIgnored private let remoteStorage: StickerUploading?
    @ObservationIgnored private let localStorage: StickerUploading
    @ObservationIgnored private let location: LocationService?
    @ObservationIgnored private var subscription: LocationSubscription?
    @ObservationIgnored private var lastCoordinate: Coordinate?
    @ObservationIgnored private let clock: () -> Date

    public init(verifier: QuestVerifying,
                extractor: StickerExtracting = VisionStickerExtractor(),
                remoteStorage: StickerUploading?,
                localStorage: StickerUploading = LocalStickerStorage(),
                location: LocationService?,
                clock: @escaping () -> Date = Date.init) {
        self.verifier = verifier
        self.extractor = extractor
        self.remoteStorage = remoteStorage
        self.localStorage = localStorage
        self.location = location
        self.clock = clock
        subscription = location?.subscribe { [weak self] step in self?.updateLocation(step.fix.coordinate) }
        if let here = location?.currentCoordinate { lastCoordinate = here }
    }

    /// Set today's quest (from `QuestService.today`).
    public func setQuest(_ quest: Quest?) {
        guard quest?.id != self.quest?.id else { return }
        self.quest = quest
        state = quest == nil ? .noQuest : .locked
        distanceToTarget = nil
        if let c = lastCoordinate { updateLocation(c) }
    }

    /// Feed a position (called automatically from `LocationService`; public for tests).
    public func updateLocation(_ c: Coordinate) {
        lastCoordinate = c
        guard let quest else { return }
        let d = Geo.distance(c, quest.target)
        distanceToTarget = d
        switch state {
        case .locked where d <= unlockRadius: state = .ready
        case .ready where d > relockRadius: state = .locked
        default: break
        }
    }

    /// Submit a photo from the in-app camera (Q-6). Only works when `canCapture`.
    public func capture(_ photo: CGImage) async {
        guard canCapture, let quest, let here = lastCoordinate else { return }
        state = .verifying
        let capturedAt = clock()

        guard let jpeg = ImageEncoding.jpeg(photo) else {
            state = .error("Couldn't process the photo.")
            return
        }
        let request = VerifyQuestRequest(questId: quest.id, photoBase64: jpeg.base64EncodedString(),
                                         location: here, capturedAt: capturedAt)

        // Cut out the sticker while the AI verifies.
        async let stickerImage = extractor.extractSticker(from: photo)
        let result: VerificationResult
        do {
            result = try await verifier.verify(request, quest: quest, image: photo)
        } catch {
            _ = await stickerImage
            state = .error("Couldn't reach the verifier. Check your connection and try again.")
            return
        }

        guard result.verified, result.confidence >= minimumConfidence else {
            _ = await stickerImage
            state = result.attemptsRemaining > 0
                ? .rejected(reason: result.reason, attemptsRemaining: result.attemptsRemaining)
                : .outOfAttempts
            return
        }

        let sticker = await saveSticker(await stickerImage, quest: quest, at: here, date: capturedAt)
        state = .success(sticker)
        onSuccess?(sticker, quest)
    }

    /// After `.rejected` or `.error`: back to `.ready` (or `.locked` if the user walked away).
    public func retry() {
        switch state {
        case .rejected, .error: break
        default: return
        }
        state = .locked
        if let c = lastCoordinate { updateLocation(c) }
    }

    private func saveSticker(_ image: CGImage, quest: Quest, at c: Coordinate, date: Date) async -> Sticker {
        var sticker = Sticker(questID: quest.id, category: quest.category, questDate: quest.date,
                              location: c, collectedAt: date)
        guard let png = ImageEncoding.png(image) else { return sticker }
        sticker.localImageURL = try? await localStorage.upload(png: png, questID: quest.id)
        // Remote upload failing shouldn't fail the quest; the local copy still shows in the sticker book.
        sticker.imageURL = try? await remoteStorage?.upload(png: png, questID: quest.id)
        return sticker
    }
}
