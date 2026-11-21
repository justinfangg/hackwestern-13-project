import Foundation
import FogCore

// Request/response bodies for the Supabase Edge Functions (PRD §10.1).
//
// PROVISIONAL: these are FogKit's proposal until Vishaal's API contract (docs/api.md) lands.
// When it does, update only this file. JSON uses snake_case keys and ISO-8601 dates (see JSONCoding).

// MARK: sync (POST)

public struct TileClear: Hashable, Codable, Sendable {
    public var tile: TileID          // hex string in JSON
    public var clearedAt: Date
    public init(tile: TileID, clearedAt: Date) {
        self.tile = tile
        self.clearedAt = clearedAt
    }
}

public struct ExpeditionRecord: Hashable, Codable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var distanceM: Double
    public var newTiles: Int
    public var segments: [[Coordinate]]

    public init(_ s: ExpeditionSummary) {
        id = s.id
        startedAt = s.startedAt
        endedAt = s.endedAt
        distanceM = s.distanceMeters
        newTiles = s.newTiles
        segments = s.segments
    }
}

public struct SyncRequest: Codable, Sendable {
    public var tiles: [TileClear]
    public var pings: [LocationPing]
    public var expeditions: [ExpeditionRecord]

    public init(tiles: [TileClear], pings: [LocationPing], expeditions: [ExpeditionRecord]) {
        self.tiles = tiles
        self.pings = pings
        self.expeditions = expeditions
    }
}

public struct SyncResponse: Codable, Sendable {
    public var acceptedTiles: Int
    public var acceptedPings: Int

    public init(acceptedTiles: Int, acceptedPings: Int) {
        self.acceptedTiles = acceptedTiles
        self.acceptedPings = acceptedPings
    }
}

// MARK: quest-today (GET ?lat=&lng=)

public struct QuestTodayResponse: Codable, Sendable {
    /// nil when there's no quest (e.g. 23:00–05:00, or no objects in the region).
    public var quest: Quest?

    public init(quest: Quest?) { self.quest = quest }
}

// MARK: verify-quest (POST)

public struct VerifyQuestRequest: Codable, Sendable {
    public var questId: UUID
    /// JPEG, longest side ≤ 1024 px, base64-encoded.
    public var photoBase64: String
    public var location: Coordinate
    public var capturedAt: Date

    public init(questId: UUID, photoBase64: String, location: Coordinate, capturedAt: Date) {
        self.questId = questId
        self.photoBase64 = photoBase64
        self.location = location
        self.capturedAt = capturedAt
    }
}

// Response: VerificationResult (FogCore).

// MARK: profile (GET)

public struct ProfileStats: Hashable, Codable, Sendable {
    public var tilesCleared: Int
    public var distanceM: Double
    public var questsCompleted: Int
    public var currentStreak: Int

    public init(tilesCleared: Int, distanceM: Double, questsCompleted: Int, currentStreak: Int) {
        self.tilesCleared = tilesCleared
        self.distanceM = distanceM
        self.questsCompleted = questsCompleted
        self.currentStreak = currentStreak
    }
}

public struct WeeklyActivity: Hashable, Codable, Sendable, Identifiable {
    public var weekStart: String     // "YYYY-MM-DD" (Monday)
    public var distanceM: Double
    public var newTiles: Int
    public var id: String { weekStart }

    public init(weekStart: String, distanceM: Double, newTiles: Int) {
        self.weekStart = weekStart
        self.distanceM = distanceM
        self.newTiles = newTiles
    }
}

public struct ProfileResponse: Codable, Sendable {
    public var username: String
    public var stats: ProfileStats
    public var stickers: [Sticker]
    /// Quest dates the user missed, for greyed-out silhouettes (PRD Q-13).
    public var missedQuestDates: [String]
    /// Last ~8 weeks, oldest first (PRD P-5, from the `daily_activity` view).
    public var weeklyActivity: [WeeklyActivity]

    public init(username: String, stats: ProfileStats, stickers: [Sticker],
                missedQuestDates: [String], weeklyActivity: [WeeklyActivity]) {
        self.username = username
        self.stats = stats
        self.stickers = stickers
        self.missedQuestDates = missedQuestDates
        self.weeklyActivity = weeklyActivity
    }

    public static let sample = ProfileResponse(
        username: "explorer",
        stats: ProfileStats(tilesCleared: 1_284, distanceM: 42_300, questsCompleted: 6, currentStreak: 3),
        stickers: [],
        missedQuestDates: ["2026-11-18"],
        weeklyActivity: (0..<8).map {
            WeeklyActivity(weekStart: "2026-10-\(String(format: "%02d", 1 + $0 * 4))",
                           distanceM: Double(3_000 + $0 * 900), newTiles: 60 + $0 * 25)
        })
}
