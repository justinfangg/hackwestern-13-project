import Foundation
import CoreGraphics
import Vision
import FogCore
import FogNetworking

/// Checks whether a photo shows the quest object.
public protocol QuestVerifying: Sendable {
    func verify(_ request: VerifyQuestRequest, quest: Quest, image: CGImage) async throws -> VerificationResult
}

/// Production path: the `verify-quest` Edge Function (Gemini vision + server-side geofence, PRD Q-7).
/// Throws `APIError.server` for `too_far`, `already_completed`, `no_attempts_left`, … (docs/api.md §4).
public struct RemoteQuestVerifier: QuestVerifying {
    private let api: FogAPI
    public init(api: FogAPI) { self.api = api }

    public func verify(_ request: VerifyQuestRequest, quest: Quest, image: CGImage) async throws -> VerificationResult {
        try await api.verifyQuest(request).result
    }
}

/// Offline fallback behind the debug toggle (PRD §14): Apple's on-device image classifier.
/// Much less accurate than the LLM and no anti-cheat; for flaky venue Wi-Fi only.
public actor OnDeviceQuestVerifier: QuestVerifying {
    /// Classifier labels that count as each quest category.
    public static let synonyms: [String: [String]] = [
        "bench": ["bench", "park_bench"],
        "lamppost": ["streetlight", "lamp", "lamppost", "light_post", "street_light"],
        "tree": ["tree", "conifer", "deciduous_tree", "evergreen", "plant"],
        "hydrant": ["fire_hydrant", "hydrant"],
        "mural": ["mural", "graffiti", "painting", "art"],
        "statue": ["statue", "sculpture", "monument"],
        "mailbox": ["mailbox", "postbox", "mail"],
        "flower": ["flower", "daisy", "rose", "tulip", "sunflower", "lily", "orchid", "petal", "blossom"],
        "chair": ["chair", "armchair", "folding_chair", "rocking_chair", "office_chair", "seat"],
    ]

    public let minimumConfidence: Float
    private var attemptsUsed: [UUID: Int] = [:]
    private let maxAttempts = 5

    public init(minimumConfidence: Float = 0.2) { self.minimumConfidence = minimumConfidence }

    public func verify(_ request: VerifyQuestRequest, quest: Quest, image: CGImage) async throws -> VerificationResult {
        let used = attemptsUsed[request.questId, default: 0] + 1
        attemptsUsed[request.questId] = used
        let remaining = max(0, maxAttempts - used)

        let classify = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([classify])
        let labels = (classify.results ?? []).filter { $0.confidence >= minimumConfidence }
        let wanted = Self.synonyms[quest.category] ?? [quest.category]
        if let match = labels.first(where: { label in wanted.contains { label.identifier.contains($0) } }) {
            return VerificationResult(verified: true, confidence: Double(match.confidence),
                                      reason: "On-device match: \(match.identifier)", attemptsLeft: remaining)
        }
        let top = labels.prefix(3).map(\.identifier).joined(separator: ", ")
        return VerificationResult(verified: false, confidence: 0,
                                  reason: top.isEmpty ? "Couldn't recognise the object." : "Saw: \(top)",
                                  attemptsLeft: remaining)
    }
}
