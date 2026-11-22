import Foundation

/// Today's Daily Quest for the user's region (PRD Q-1, Q-2). App-side model; the wire format is
/// `QuestTodayResponse` in FogNetworking.
public struct Quest: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var date: String            // "YYYY-MM-DD", America/Toronto
    public var category: String        // "bench", "lamppost", "tree", "fire_hydrant", ...
    public var hint: String
    public var placeName: String?
    public var target: Coordinate
    public var geofenceRadiusM: Double
    public var foundTodayCount: Int    // Q-11

    public init(id: UUID = UUID(), date: String, category: String, hint: String, placeName: String? = nil,
                target: Coordinate, geofenceRadiusM: Double = 40, foundTodayCount: Int = 0) {
        self.id = id
        self.date = date
        self.category = category
        self.hint = hint
        self.placeName = placeName
        self.target = target
        self.geofenceRadiusM = geofenceRadiusM
        self.foundTodayCount = foundTodayCount
    }

    /// "Find the bench", "Find the fire hydrant".
    public var title: String { "Find the \(QuestCategory.displayName(category))" }

    public static let sample = Quest(
        id: UUID(uuidString: "b7e4d1c2-5a3f-4c8e-9d16-2f0a7b3c8e91")!,
        date: "2026-11-21", category: "bench",
        hint: "A wooden bench facing the hill, just below the tower.",
        placeName: "University College Hill",
        target: Geo.offset(.westernCampus, north: 120, east: 60), foundTodayCount: 8)
}

/// Display helpers for quest categories. Unknown categories must still display (docs/api.md §1).
public enum QuestCategory {
    public static let known = ["bench", "lamppost", "tree", "fire_hydrant", "mural", "statue", "mailbox", "chair", "flower"]

    public static func displayName(_ category: String) -> String {
        category.replacingOccurrences(of: "_", with: " ")
    }

    /// A suggested SF Symbol; falls back to a generic star for unknown categories.
    public static func symbolName(_ category: String) -> String {
        switch category {
        case "bench": "chair.lounge.fill"
        case "lamppost": "lightbulb.fill"
        case "tree": "tree.fill"
        case "fire_hydrant": "drop.fill"
        case "mural": "paintpalette.fill"
        case "statue": "building.columns.fill"
        case "mailbox": "envelope.fill"
        case "chair": "chair.fill"
        case "flower": "camera.macro"
        default: "star.fill"
        }
    }
}

/// Result of verifying a quest photo (PRD Q-7, Q-12). `verified` is the server's final answer.
public struct VerificationResult: Hashable, Sendable {
    public var verified: Bool
    public var confidence: Double
    public var reason: String
    public var attemptsLeft: Int
    /// Set when verified.
    public var completionID: UUID?
    public var stickerURL: URL?
    public var completedAt: Date?
    /// The new current streak after this completion.
    public var streak: Int?

    public init(verified: Bool, confidence: Double, reason: String, attemptsLeft: Int,
                completionID: UUID? = nil, stickerURL: URL? = nil, completedAt: Date? = nil, streak: Int? = nil) {
        self.verified = verified
        self.confidence = confidence
        self.reason = reason
        self.attemptsLeft = attemptsLeft
        self.completionID = completionID
        self.stickerURL = stickerURL
        self.completedAt = completedAt
        self.streak = streak
    }
}

/// A collected quest sticker (PRD Q-8, P-1).
public struct Sticker: Identifiable, Hashable, Codable, Sendable {
    /// The completion id from the server (or a local id until it's known).
    public var id: UUID
    public var questID: UUID
    public var category: String
    public var questDate: String
    /// The quest target.
    public var location: Coordinate
    public var placeName: String?
    public var hint: String?
    public var collectedAt: Date
    /// Public URL in the `stickers` bucket (uploaded by the server).
    public var imageURL: URL?
    /// Local PNG (transparent background), available immediately after capture.
    public var localImageURL: URL?

    public init(id: UUID = UUID(), questID: UUID, category: String, questDate: String, location: Coordinate,
                placeName: String? = nil, hint: String? = nil, collectedAt: Date,
                imageURL: URL? = nil, localImageURL: URL? = nil) {
        self.id = id
        self.questID = questID
        self.category = category
        self.questDate = questDate
        self.location = location
        self.placeName = placeName
        self.hint = hint
        self.collectedAt = collectedAt
        self.imageURL = imageURL
        self.localImageURL = localImageURL
    }

    /// `JSONCoding` converts keys to and from snake_case, and "image_url" converts back to
    /// "imageUrl", not "imageURL". Without these the URLs silently decode as nil (a saved sticker
    /// loses its artwork after a relaunch). On disk the keys stay "image_url" / "local_image_url".
    private enum CodingKeys: String, CodingKey {
        case id, questID = "questId", category, questDate, location, placeName, hint, collectedAt
        case imageURL = "imageUrl", localImageURL = "localImageUrl"
    }
}
