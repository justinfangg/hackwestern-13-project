import Foundation
import FogCore

// Request/response bodies for the four Supabase Edge Functions, matching docs/api.md v0.2.
// Encoded/decoded with JSONCoding: snake_case keys, ISO-8601 dates. CodingKeys raw values are camelCase.
// Tested against every file in docs/mocks (ContractTests).

// MARK: - POST sync (§2)

public struct TileClear: Hashable, Codable, Sendable {
    public var h3: TileID            // lowercase hex string in JSON
    public var clearedAt: Date

    public init(h3: TileID, clearedAt: Date) {
        self.h3 = h3
        self.clearedAt = clearedAt
    }
}

/// An expedition as sent to `sync`. `endedAt == nil` while it's running. No route: the server builds
/// it from the pings.
public struct ExpeditionRecord: Hashable, Codable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var distanceM: Double
    public var newTiles: Int

    public init(id: UUID, startedAt: Date, endedAt: Date?, distanceM: Double, newTiles: Int) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceM = distanceM
        self.newTiles = newTiles
    }

    public init(_ s: ExpeditionSummary) {
        self.init(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt,
                  distanceM: s.distanceMeters, newTiles: s.newTiles)
    }

    private enum CodingKeys: String, CodingKey { case id, startedAt, endedAt, distanceM, newTiles }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)   // explicit null while running
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(newTiles, forKey: .newTiles)
    }
}

public struct SyncRequest: Encodable, Sendable {
    public var expeditions: [ExpeditionRecord]
    public var pings: [LocationPing]
    public var tiles: [TileClear]

    public init(expeditions: [ExpeditionRecord], pings: [LocationPing], tiles: [TileClear]) {
        self.expeditions = expeditions
        self.pings = pings
        self.tiles = tiles
    }

    /// Server limits per request (§2).
    public static let maxTiles = 5_000, maxPings = 2_000, maxExpeditions = 50
}

public struct SyncResponse: Codable, Sendable {
    public struct Rejected: Codable, Sendable {
        public var tiles: Int, pings: Int, expeditions: Int
        public init(tiles: Int = 0, pings: Int = 0, expeditions: Int = 0) {
            self.tiles = tiles
            self.pings = pings
            self.expeditions = expeditions
        }
    }
    public var newTiles: Int
    public var totalTiles: Int
    public var rejected: Rejected
    public var serverTime: Date

    public init(newTiles: Int, totalTiles: Int, rejected: Rejected = .init(), serverTime: Date = Date()) {
        self.newTiles = newTiles
        self.totalTiles = totalTiles
        self.rejected = rejected
        self.serverTime = serverTime
    }
}

// MARK: - GET quest-today (§3)

public enum QuestStatus: Hashable, Codable, Sendable {
    case active, noneInRegion, quietHours, unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "active": self = .active
        case "none_in_region": self = .noneInRegion
        case "quiet_hours": self = .quietHours
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .active: try c.encode("active")
        case .noneInRegion: try c.encode("none_in_region")
        case .quietHours: try c.encode("quiet_hours")
        case .unknown(let raw): try c.encode(raw)
        }
    }
}

/// One of today's quests plus the player's progress on it (Quests sheet row).
public struct QuestOption: Hashable, Sendable, Identifiable {
    public var quest: Quest
    public var completedByMe: Bool
    public var attemptsLeft: Int
    public var id: UUID { quest.id }
    public init(quest: Quest, completedByMe: Bool, attemptsLeft: Int) {
        self.quest = quest
        self.completedByMe = completedByMe
        self.attemptsLeft = attemptsLeft
    }
}

public struct QuestDTO: Hashable, Codable, Sendable {
    public var id: UUID
    public var category: String
    public var hint: String
    public var placeName: String?
    public var target: Coordinate
    public var geofenceRadiusM: Double

    public init(id: UUID, category: String, hint: String, placeName: String?, target: Coordinate, geofenceRadiusM: Double) {
        self.id = id
        self.category = category
        self.hint = hint
        self.placeName = placeName
        self.target = target
        self.geofenceRadiusM = geofenceRadiusM
    }
}

public struct QuestTodayResponse: Codable, Sendable {
    public var date: String
    public var regionH3: String
    public var status: QuestStatus
    public var availableAt: Date?
    public var resetsAt: Date
    public var quest: QuestDTO?
    public var foundToday: Int
    public var completedByMe: Bool
    public var attemptsLeft: Int
    /// Every quest in the region today, first = `quest`. nil from servers before multiple quests.
    public var quests: [Entry]?

    /// One of today's quests with the caller's progress on it.
    public struct Entry: Codable, Sendable {
        public var quest: QuestDTO
        public var foundToday: Int
        public var completedByMe: Bool
        public var attemptsLeft: Int
        public init(quest: QuestDTO, foundToday: Int, completedByMe: Bool, attemptsLeft: Int) {
            self.quest = quest
            self.foundToday = foundToday
            self.completedByMe = completedByMe
            self.attemptsLeft = attemptsLeft
        }
    }

    public init(date: String, regionH3: String, status: QuestStatus, availableAt: Date? = nil, resetsAt: Date,
                quest: QuestDTO?, foundToday: Int, completedByMe: Bool, attemptsLeft: Int, quests: [Entry]? = nil) {
        self.date = date
        self.regionH3 = regionH3
        self.status = status
        self.availableAt = availableAt
        self.resetsAt = resetsAt
        self.quest = quest
        self.foundToday = foundToday
        self.completedByMe = completedByMe
        self.attemptsLeft = attemptsLeft
        self.quests = quests
    }

    /// All of today's quests, app-side (empty when there's none). Falls back to the single `quest`.
    public var appQuests: [QuestOption] {
        guard status == .active else { return [] }
        let entries = quests ?? quest.map {
            [Entry(quest: $0, foundToday: foundToday, completedByMe: completedByMe, attemptsLeft: attemptsLeft)]
        } ?? []
        return entries.map { e in
            let q = e.quest
            return QuestOption(
                quest: Quest(id: q.id, date: date, category: q.category, hint: q.hint, placeName: q.placeName,
                             target: q.target, geofenceRadiusM: q.geofenceRadiusM, foundTodayCount: e.foundToday),
                completedByMe: e.completedByMe, attemptsLeft: e.attemptsLeft)
        }
    }

    /// The app-side quest, or nil when there's no quest today.
    public var appQuest: Quest? {
        guard status == .active, let q = quest else { return nil }
        return Quest(id: q.id, date: date, category: q.category, hint: q.hint, placeName: q.placeName,
                     target: q.target, geofenceRadiusM: q.geofenceRadiusM, foundTodayCount: foundToday)
    }
}

// MARK: - POST verify-quest (§4)

public struct VerifyQuestRequest: Codable, Sendable {
    public var questId: UUID
    public var lat: Double
    public var lng: Double
    public var accuracyM: Double
    public var capturedAt: Date
    /// JPEG, long edge ≤ 1024 px, standard base64, no `data:` prefix.
    public var photoJpegBase64: String
    /// Transparent PNG, long edge ≤ 512 px.
    public var stickerPngBase64: String

    public init(questId: UUID, location: Coordinate, accuracyM: Double, capturedAt: Date,
                photoJpegBase64: String, stickerPngBase64: String) {
        self.questId = questId
        self.lat = location.latitude
        self.lng = location.longitude
        self.accuracyM = accuracyM
        self.capturedAt = capturedAt
        self.photoJpegBase64 = photoJpegBase64
        self.stickerPngBase64 = stickerPngBase64
    }
}

public struct VerifyQuestResponse: Codable, Sendable {
    public struct Completion: Codable, Sendable {
        public var id: UUID
        public var stickerUrl: URL
        public var completedAt: Date
        public init(id: UUID, stickerUrl: URL, completedAt: Date) {
            self.id = id
            self.stickerUrl = stickerUrl
            self.completedAt = completedAt
        }
    }
    public var verified: Bool
    public var confidence: Double
    public var reason: String
    public var attemptsLeft: Int
    public var completion: Completion?
    public var streak: Int?

    public init(verified: Bool, confidence: Double, reason: String, attemptsLeft: Int,
                completion: Completion? = nil, streak: Int? = nil) {
        self.verified = verified
        self.confidence = confidence
        self.reason = reason
        self.attemptsLeft = attemptsLeft
        self.completion = completion
        self.streak = streak
    }

    public var result: VerificationResult {
        VerificationResult(verified: verified, confidence: confidence, reason: reason, attemptsLeft: attemptsLeft,
                           completionID: completion?.id, stickerURL: completion?.stickerUrl,
                           completedAt: completion?.completedAt, streak: streak)
    }
}

// MARK: - GET profile (§5)

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

public struct ProfileSticker: Hashable, Codable, Sendable {
    public var completionId: UUID
    public var questId: UUID
    public var date: String
    public var category: String
    public var place: Coordinate
    public var placeName: String?
    public var hint: String?
    public var stickerUrl: URL
    public var completedAt: Date

    public var sticker: Sticker {
        Sticker(id: completionId, questID: questId, category: category, questDate: date, location: place,
                placeName: placeName, hint: hint, collectedAt: completedAt, imageURL: stickerUrl)
    }
}

/// A day with no completion; shown as a greyed silhouette (PRD Q-13).
public struct MissedDay: Hashable, Codable, Sendable, Identifiable {
    public var date: String
    public var category: String?
    public var id: String { date }
}

public struct WeeklyActivity: Hashable, Codable, Sendable, Identifiable {
    public var weekStart: String     // "YYYY-MM-DD" (Monday, Toronto)
    public var distanceM: Double
    public var newTiles: Int
    public var id: String { weekStart }

    public init(weekStart: String, distanceM: Double, newTiles: Int) {
        self.weekStart = weekStart
        self.distanceM = distanceM
        self.newTiles = newTiles
    }
}

public struct ProfileExpedition: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var durationS: Int
    public var distanceM: Double
    public var newTiles: Int
}

public struct ProfileRoute: Hashable, Codable, Sendable {
    public var expeditionId: UUID
    public var points: [Coordinate]
}

public struct ProfileResponse: Codable, Sendable {
    public var userId: UUID
    /// nil until `POST profile` sets it.
    public var username: String?
    public var createdAt: Date
    public var stats: ProfileStats
    public var stickers: [ProfileSticker]
    public var missedDays: [MissedDay]
    /// Last 8 weeks, oldest first.
    public var weeklyActivity: [WeeklyActivity]
    public var expeditions: [ProfileExpedition]
    public var routes: [ProfileRoute]
    /// Only with `?include=tiles` (D8).
    public var tiles: [TileID]?

    public static let sample = ProfileResponse(
        userId: UUID(), username: "explorer", createdAt: Date(timeIntervalSince1970: 1_794_000_000),
        stats: ProfileStats(tilesCleared: 138, distanceM: 1_671.7, questsCompleted: 6, currentStreak: 4),
        stickers: [], missedDays: [MissedDay(date: "2026-11-17", category: "tree")],
        weeklyActivity: (0..<8).map {
            WeeklyActivity(weekStart: "2026-10-\(String(format: "%02d", 1 + $0 * 4))",
                           distanceM: Double(300 + $0 * 120), newTiles: 10 + $0 * 12)
        },
        expeditions: [], routes: [], tiles: nil)
}

// MARK: - POST profile (§6)

public struct SetUsernameRequest: Codable, Sendable {
    public var username: String
    public init(username: String) { self.username = username }
}

public struct ProfileIdentity: Hashable, Codable, Sendable {
    public var userId: UUID
    public var username: String?
    public var createdAt: Date
}

// MARK: - Errors (§1)

/// `{ "error": { "code", "message", "details" } }`
public struct APIErrorBody: Hashable, Codable, Sendable {
    public struct Details: Hashable, Codable, Sendable {
        public var distanceM: Double?
        public var radiusM: Double?
        public var fields: [String]?
        public init(distanceM: Double? = nil, radiusM: Double? = nil, fields: [String]? = nil) {
            self.distanceM = distanceM
            self.radiusM = radiusM
            self.fields = fields
        }
    }
    public var code: String
    public var message: String
    public var details: Details?

    public init(code: String, message: String, details: Details? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct APIErrorEnvelope: Codable, Sendable {
    public var error: APIErrorBody
}

// MARK: - GET leaderboard (§7: territory)

public enum LeaderboardMetric: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Share of the area's tiles cleared (0–100).
    case percent
    /// Seconds of movement inside the area.
    case time
    /// Metres moved inside the area.
    case distance
    public var id: String { rawValue }
}

/// Leaderboard time window, in Toronto calendar terms (weeks start Monday).
public enum LeaderboardPeriod: String, Codable, Sendable, CaseIterable, Identifiable {
    case day, week, month
    public var id: String { rawValue }
}

public struct AreaStats: Hashable, Codable, Sendable {
    public var percent: Double
    public var timeS: Double
    public var distanceM: Double

    public init(percent: Double, timeS: Double, distanceM: Double) {
        self.percent = percent
        self.timeS = timeS
        self.distanceM = distanceM
    }

    public func value(for metric: LeaderboardMetric) -> Double {
        switch metric {
        case .percent: percent
        case .time: timeS
        case .distance: distanceM
        }
    }
}

/// A territory: "campus", "park" or "neighbourhood".
public struct TerritoryArea: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var totalTiles: Int
    public var distanceFromMeM: Double?
    /// The caller's own numbers in this area.
    public var mine: AreaStats

    public init(id: String, name: String, kind: String, totalTiles: Int, distanceFromMeM: Double? = nil, mine: AreaStats) {
        self.id = id
        self.name = name
        self.kind = kind
        self.totalTiles = totalTiles
        self.distanceFromMeM = distanceFromMeM
        self.mine = mine
    }
}

public struct LeaderboardAreasResponse: Codable, Sendable {
    public var areas: [TerritoryArea]
}

public struct LeaderboardEntry: Hashable, Codable, Sendable, Identifiable {
    public var rank: Int
    public var name: String
    public var value: Double
    public var isMe: Bool
    public var id: String { "\(rank)-\(name)" }

    public init(rank: Int, name: String, value: Double, isMe: Bool) {
        self.rank = rank
        self.name = name
        self.value = value
        self.isMe = isMe
    }
}

public struct LeaderboardResponse: Codable, Sendable {
    public struct Area: Hashable, Codable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var totalTiles: Int
    }
    public var area: Area
    public var metric: LeaderboardMetric
    public var totalPlayers: Int
    /// Top 50, best first (ties share a rank).
    public var entries: [LeaderboardEntry]
    /// The caller's row, also when outside the top 50; nil if they have no score here yet.
    public var me: LeaderboardEntry?
}

// MARK: - GET feed (docs/api.md §8)

/// One finished session in the social feed.
public struct FeedPost: Hashable, Codable, Sendable, Identifiable {
    public struct Author: Hashable, Codable, Sendable {
        public var id: UUID
        public var name: String
        public var isMe: Bool
        public init(id: UUID, name: String, isMe: Bool) {
            self.id = id
            self.name = name
            self.isMe = isMe
        }
    }

    /// The territory the session started in.
    public struct Area: Hashable, Codable, Sendable {
        public var name: String
        /// "campus", "park" or "neighbourhood".
        public var kind: String
        public init(name: String, kind: String) {
            self.name = name
            self.kind = kind
        }
    }

    /// The sticker from a quest found during the session.
    public struct Find: Hashable, Codable, Sendable {
        public var url: URL
        public var category: String
        public var placeName: String?
        public init(url: URL, category: String, placeName: String?) {
            self.url = url
            self.category = category
            self.placeName = placeName
        }
    }

    /// The expedition's id.
    public var id: UUID
    public var author: Author
    public var startedAt: Date
    public var endedAt: Date
    public var durationS: Int
    public var distanceM: Double
    public var newTiles: Int
    public var area: Area?
    public var sticker: Find?
    /// The route as a shape only: points in a unit square (x right, y down, north up, longer
    /// side spanning 0–1, centred). No coordinates. Nil without a recorded route.
    public var routeShape: [ShapePoint]?

    /// A point of `routeShape`, in 0…1.
    public struct ShapePoint: Hashable, Codable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public init(id: UUID, author: Author, startedAt: Date, endedAt: Date, durationS: Int,
                distanceM: Double, newTiles: Int, area: Area?, sticker: Find?,
                routeShape: [ShapePoint]? = nil) {
        self.id = id
        self.author = author
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.newTiles = newTiles
        self.area = area
        self.sticker = sticker
        self.routeShape = routeShape
    }

    /// Average pace in seconds per km (nil for sessions too short to say).
    public var paceSecondsPerKm: Double? {
        distanceM >= 100 && durationS > 0 ? Double(durationS) / (distanceM / 1000) : nil
    }
}

public struct FeedResponse: Codable, Sendable {
    /// Newest first.
    public var posts: [FeedPost]
    /// Pass back as `before` to load older posts; nil when there are no more.
    public var nextBefore: Date?
    public init(posts: [FeedPost], nextBefore: Date?) {
        self.posts = posts
        self.nextBefore = nextBefore
    }
}

/// The city leaderboard for a period (docs/api.md §7, current app). `area` is the city you're in
/// (nil when you're not near one).
public struct CityLeaderboardResponse: Codable, Sendable {
    public var area: LeaderboardResponse.Area?
    public var metric: LeaderboardMetric
    public var period: LeaderboardPeriod
    public var periodStart: Date
    public var totalPlayers: Int
    /// Top 50, best first (ties share a rank).
    public var entries: [LeaderboardEntry]
    /// Your row, also when outside the top 50; nil with no score in this metric yet.
    public var me: LeaderboardEntry?
    /// Your numbers for all three metrics in this city and period.
    public var mine: AreaStats

    public init(area: LeaderboardResponse.Area?, metric: LeaderboardMetric, period: LeaderboardPeriod, periodStart: Date,
                totalPlayers: Int, entries: [LeaderboardEntry], me: LeaderboardEntry?, mine: AreaStats) {
        self.area = area
        self.metric = metric
        self.period = period
        self.periodStart = periodStart
        self.totalPlayers = totalPlayers
        self.entries = entries
        self.me = me
        self.mine = mine
    }
}
