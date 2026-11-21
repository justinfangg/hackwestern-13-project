import Foundation
import Observation
import CoreGraphics
import FogCore
import FogLocation
import FogNetworking

/// Drives the Daily Quest flow: geofence → capture → verify → sticker (PRD Q-5 to Q-13, docs/api.md §4).
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
        /// Photo taken; waiting for verification.
        case verifying
        /// Verified; sticker collected (Q-8).
        case success(Sticker)
        /// Not verified; show the reason and allow a retry (Q-12).
        case rejected(reason: String, attemptsLeft: Int)
        /// The server says the photo was taken too far away (GPS drift). Walk closer and retry.
        case tooFar(distanceMeters: Double)
        /// Already found today's quest.
        case alreadyCompleted
        /// Used all 5 attempts today.
        case outOfAttempts
        /// Network/server problem, or the verifier is busy; retry allowed.
        case error(String)
    }

    public private(set) var state: State = .noQuest
    public private(set) var quest: Quest?
    /// Live distance to the quest target in metres, for "420 m" on the quest card.
    public private(set) var distanceToTarget: Double?
    /// Attempts left today (from `quest-today`, then from each verification).
    public private(set) var attemptsLeft = 5
    /// Streak after the latest successful find.
    public private(set) var streak: Int?
    /// True when the camera may be used (Q-5).
    public var canCapture: Bool { state == .ready }

    /// Called once per successful find (FogKit wires this to the expedition, quest count and profile).
    @ObservationIgnored public var onSuccess: ((Sticker, Quest) -> Void)?
    /// Called when the server says the quest is no longer today's (FogKit refetches).
    @ObservationIgnored public var onQuestStale: (() -> Void)?

    @ObservationIgnored public var verifier: QuestVerifying
    @ObservationIgnored private let extractor: StickerExtracting
    @ObservationIgnored private let stickerCache: StickerUploading
    @ObservationIgnored private var subscription: LocationSubscription?
    @ObservationIgnored private var lastCoordinate: Coordinate?
    @ObservationIgnored private var lastAccuracy: Double = 10
    @ObservationIgnored private let clock: () -> Date

    public init(verifier: QuestVerifying,
                extractor: StickerExtracting = VisionStickerExtractor(),
                stickerCache: StickerUploading = LocalStickerStorage(),
                location: LocationService?,
                clock: @escaping () -> Date = Date.init) {
        self.verifier = verifier
        self.extractor = extractor
        self.stickerCache = stickerCache
        self.clock = clock
        subscription = location?.subscribe { [weak self] step in
            self?.updateLocation(step.fix.coordinate, accuracy: step.fix.horizontalAccuracy)
        }
        if let fix = location?.currentFix {
            lastCoordinate = fix.coordinate
            lastAccuracy = fix.horizontalAccuracy
        }
    }

    /// Unlock radius (PRD Q-5); from the quest, default 40 m.
    public var unlockRadius: Double { quest?.geofenceRadiusM ?? 40 }
    /// Re-lock only beyond this, so the button doesn't flicker at the edge.
    public var relockRadius: Double { unlockRadius + 10 }

    /// Set today's quest and its per-user status (from `QuestService`).
    public func setQuest(_ quest: Quest?, completedByMe: Bool = false, attemptsLeft: Int = 5) {
        let changed = quest?.id != self.quest?.id
        self.quest = quest
        self.attemptsLeft = attemptsLeft
        guard changed || state == .noQuest else { return }
        distanceToTarget = nil
        if quest == nil {
            state = .noQuest
        } else if completedByMe {
            state = .alreadyCompleted
        } else if attemptsLeft <= 0 {
            state = .outOfAttempts
        } else {
            state = .locked
        }
        if let c = lastCoordinate { updateLocation(c, accuracy: lastAccuracy) }
    }

    /// Feed a position (called automatically from `LocationService`; public for tests).
    public func updateLocation(_ c: Coordinate, accuracy: Double = 5) {
        lastCoordinate = c
        lastAccuracy = accuracy
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

        // The sticker is cut out on device and sent with the photo; the server stores both on success (D3).
        let stickerImage = await extractor.extractSticker(from: photo)
        guard let jpeg = ImageEncoding.jpeg(photo, maxDimension: 1024, quality: 0.7),
              let stickerPNG = ImageEncoding.png(ImageEncoding.downscaled(stickerImage, maxDimension: 512)) else {
            state = .error("Couldn't process the photo.")
            return
        }
        let request = VerifyQuestRequest(questId: quest.id, location: here, accuracyM: max(lastAccuracy, 0),
                                         capturedAt: capturedAt,
                                         photoJpegBase64: jpeg.base64EncodedString(),
                                         stickerPngBase64: stickerPNG.base64EncodedString())

        let result: VerificationResult
        do {
            result = try await verifier.verify(request, quest: quest, image: photo)
        } catch let error as APIError {
            state = state(for: error)
            return
        } catch {
            state = .error("Couldn't reach the verifier. Check your connection and try again.")
            return
        }

        attemptsLeft = result.attemptsLeft
        // `verified` is the server's final answer; no client-side threshold (docs/api.md §4).
        guard result.verified else {
            state = result.attemptsLeft > 0
                ? .rejected(reason: result.reason, attemptsLeft: result.attemptsLeft)
                : .outOfAttempts
            return
        }

        streak = result.streak
        var sticker = Sticker(id: result.completionID ?? UUID(), questID: quest.id, category: quest.category,
                              questDate: quest.date, location: quest.target, placeName: quest.placeName,
                              hint: quest.hint, collectedAt: result.completedAt ?? capturedAt,
                              imageURL: result.stickerURL)
        sticker.localImageURL = try? await stickerCache.upload(png: stickerPNG, questID: quest.id)
        state = .success(sticker)
        onSuccess?(sticker, quest)
    }

    /// After `.rejected`, `.tooFar` or `.error`: back to `.ready` (or `.locked` if the user walked away).
    public func retry() {
        switch state {
        case .rejected, .error, .tooFar: break
        default: return
        }
        state = .locked
        if let c = lastCoordinate { updateLocation(c, accuracy: lastAccuracy) }
    }

    private func state(for error: APIError) -> State {
        switch error.code {
        case "too_far":
            if case .server(_, let body) = error, let d = body.details?.distanceM { return .tooFar(distanceMeters: d) }
            return .tooFar(distanceMeters: distanceToTarget ?? 0)
        case "already_completed":
            return .alreadyCompleted
        case "no_attempts_left":
            attemptsLeft = 0
            return .outOfAttempts
        case "not_todays_quest", "quest_not_found":
            onQuestStale?()
            return .error("Today's quest has changed. Refreshing…")
        case "verifier_unavailable":
            return .error("The verifier is busy right now. Try again in a moment; this didn't use an attempt.")
        default:
            if case .server(_, let body) = error { return .error(body.message) }
            return .error("Couldn't reach the verifier. Check your connection and try again.")
        }
    }
}
