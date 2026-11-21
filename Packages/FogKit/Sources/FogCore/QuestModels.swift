import Foundation

/// Today's Daily Quest for the user's region (PRD Q-1, Q-2).
public struct Quest: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var date: String            // "YYYY-MM-DD", region-local
    public var category: String        // "bench", "lamppost", "tree", ...
    public var title: String           // "Find the bench"
    public var hint: String
    public var target: Coordinate
    public var foundTodayCount: Int    // Q-11

    public init(id: UUID = UUID(), date: String, category: String, title: String, hint: String,
                target: Coordinate, foundTodayCount: Int = 0) {
        self.id = id
        self.date = date
        self.category = category
        self.title = title
        self.hint = hint
        self.target = target
        self.foundTodayCount = foundTodayCount
    }

    public static let sample = Quest(
        date: "2026-11-21", category: "bench", title: "Find the bench",
        hint: "Facing the UC Hill, where students eat lunch.",
        target: Geo.offset(.westernCampus, north: 120, east: 60), foundTodayCount: 8)
}

/// Result of AI verification of a quest photo (PRD Q-7, Q-12).
public struct VerificationResult: Hashable, Codable, Sendable {
    public var verified: Bool
    public var confidence: Double
    public var reason: String
    public var attemptsRemaining: Int

    public init(verified: Bool, confidence: Double, reason: String, attemptsRemaining: Int) {
        self.verified = verified
        self.confidence = confidence
        self.reason = reason
        self.attemptsRemaining = attemptsRemaining
    }
}

/// A collected quest sticker (PRD Q-8, P-1).
public struct Sticker: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var questID: UUID
    public var category: String
    public var questDate: String
    public var location: Coordinate
    public var collectedAt: Date
    /// Remote URL once uploaded to Supabase Storage.
    public var imageURL: URL?
    /// Local PNG file (transparent background), available immediately after capture.
    public var localImageURL: URL?

    public init(id: UUID = UUID(), questID: UUID, category: String, questDate: String, location: Coordinate,
                collectedAt: Date, imageURL: URL? = nil, localImageURL: URL? = nil) {
        self.id = id
        self.questID = questID
        self.category = category
        self.questDate = questDate
        self.location = location
        self.collectedAt = collectedAt
        self.imageURL = imageURL
        self.localImageURL = localImageURL
    }
}
