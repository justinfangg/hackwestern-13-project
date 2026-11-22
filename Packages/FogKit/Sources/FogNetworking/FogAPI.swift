import Foundation
import FogCore

/// Supabase project settings (Project Settings → API Keys).
/// The publishable (anon) key is safe to ship in the app; never put the secret key or a database URL here.
public struct BackendConfig: Sendable {
    public var projectURL: URL
    public var anonKey: String

    public init(projectURL: URL, anonKey: String) {
        self.projectURL = projectURL
        self.anonKey = anonKey
    }
}

public enum APIError: Error, Equatable, Sendable {
    /// An error from our Edge Functions (docs/api.md §1). Switch on `code` for user-facing copy.
    case server(status: Int, body: APIErrorBody)
    /// A non-2xx response without our error shape (e.g. the Supabase gateway).
    case http(status: Int, body: String)
    case invalidResponse

    /// The error code (`too_far`, `already_completed`, …), if the server sent one.
    public var code: String? {
        if case .server(_, let body) = self { return body.code }
        return nil
    }

    public var status: Int? {
        switch self {
        case .server(let s, _), .http(let s, _): return s
        case .invalidResponse: return nil
        }
    }
}

/// The Edge Functions (docs/api.md). `LiveFogAPI` calls them; `MockFogAPI` fakes them.
public protocol FogAPI: Sendable {
    func sync(_ request: SyncRequest) async throws -> SyncResponse
    func questToday(at location: Coordinate) async throws -> QuestTodayResponse
    func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerifyQuestResponse
    func profile(includeTiles: Bool) async throws -> ProfileResponse
    func setUsername(_ username: String) async throws -> ProfileIdentity
    /// Territory areas, nearest to `location` first, with the caller's stats (§7).
    func leaderboardAreas(near location: Coordinate?) async throws -> LeaderboardAreasResponse
    /// Ranking for one area and metric (§7).
    func leaderboard(area: String, metric: LeaderboardMetric) async throws -> LeaderboardResponse
    /// The leaderboard for the city around `location`, over today / this week / this month (§7).
    func cityLeaderboard(near location: Coordinate, metric: LeaderboardMetric, period: LeaderboardPeriod) async throws -> CityLeaderboardResponse
    /// Finished sessions from everyone, newest first (§8). `before` pages back from `nextBefore`.
    func feed(before: Date?, limit: Int) async throws -> FeedResponse
}

extension FogAPI {
    public func profile() async throws -> ProfileResponse { try await profile(includeTiles: false) }
}

public final class LiveFogAPI: FogAPI {
    private let config: BackendConfig
    private let auth: AuthTokenProviding
    private let session: URLSession

    public init(config: BackendConfig, auth: AuthTokenProviding, session: URLSession = .shared) {
        self.config = config
        self.auth = auth
        self.session = session
    }

    public func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await call("sync", method: "POST", body: request)
    }

    public func questToday(at location: Coordinate) async throws -> QuestTodayResponse {
        try await call("quest-today", query: [
            URLQueryItem(name: "lat", value: String(location.latitude)),
            URLQueryItem(name: "lng", value: String(location.longitude)),
        ])
    }

    public func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerifyQuestResponse {
        try await call("verify-quest", method: "POST", body: request)
    }

    public func profile(includeTiles: Bool) async throws -> ProfileResponse {
        try await call("profile", query: includeTiles ? [URLQueryItem(name: "include", value: "tiles")] : [])
    }

    public func setUsername(_ username: String) async throws -> ProfileIdentity {
        try await call("profile", method: "POST", body: SetUsernameRequest(username: username))
    }

    public func leaderboardAreas(near location: Coordinate?) async throws -> LeaderboardAreasResponse {
        try await call("leaderboard", query: location.map {
            [URLQueryItem(name: "lat", value: String($0.latitude)), URLQueryItem(name: "lng", value: String($0.longitude))]
        } ?? [])
    }

    public func leaderboard(area: String, metric: LeaderboardMetric) async throws -> LeaderboardResponse {
        try await call("leaderboard", query: [URLQueryItem(name: "area", value: area),
                                              URLQueryItem(name: "metric", value: metric.rawValue)])
    }

    public func cityLeaderboard(near location: Coordinate, metric: LeaderboardMetric,
                                period: LeaderboardPeriod) async throws -> CityLeaderboardResponse {
        try await call("leaderboard", query: [
            URLQueryItem(name: "lat", value: String(location.latitude)),
            URLQueryItem(name: "lng", value: String(location.longitude)),
            URLQueryItem(name: "metric", value: metric.rawValue),
            URLQueryItem(name: "period", value: period.rawValue),
        ])
    }

    public func feed(before: Date?, limit: Int) async throws -> FeedResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            query.append(URLQueryItem(name: "before", value: formatter.string(from: before)))
        }
        return try await call("feed", query: query)
    }

    // MARK: Plumbing

    private struct NoBody: Encodable {}

    private func call<Response: Decodable>(_ function: String, method: String = "GET",
                                           query: [URLQueryItem] = []) async throws -> Response {
        try await call(function, method: method, query: query, body: NoBody?.none)
    }

    private func call<Body: Encodable, Response: Decodable>(_ function: String, method: String = "GET",
                                                            query: [URLQueryItem] = [],
                                                            body: Body?) async throws -> Response {
        let bodyData = try body.map { try JSONCoding.encoder.encode($0) }
        do {
            return try await send(function, method: method, query: query, body: bodyData, forceRefresh: false)
        } catch let error as APIError where error.status == 401 {
            // Any 401 (ours or the gateway's): refresh the session and retry once (§1).
            return try await send(function, method: method, query: query, body: bodyData, forceRefresh: true)
        }
    }

    private func send<Response: Decodable>(_ function: String, method: String, query: [URLQueryItem],
                                           body: Data?, forceRefresh: Bool) async throws -> Response {
        var components = URLComponents(url: config.projectURL.appendingPathComponent("functions/v1/\(function)"),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        let token = try await auth.accessToken(forceRefresh: forceRefresh)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONCoding.decoder.decode(APIErrorEnvelope.self, from: data) {
                throw APIError.server(status: http.statusCode, body: envelope.error)
            }
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONCoding.decoder.decode(Response.self, from: data)
    }
}

/// In-memory fake backend so the app runs end to end without Supabase. Follows the same rules as
/// the real functions where it matters (attempt counting, already-completed, found-today).
public actor MockFogAPI: FogAPI {
    public var quest: Quest?
    /// More quests in the same region today (the real server can return several).
    public var extraQuests: [Quest]
    /// Next verification outcome; nil = verified.
    public var nextVerification: VerifyQuestResponse?
    /// Next verification error (e.g. `verifier_unavailable`), checked before `nextVerification`.
    public var nextVerifyError: APIError?
    public var latency: Duration
    public var failSync = false
    public private(set) var syncRequests: [SyncRequest] = []
    public private(set) var verifyRequests: [VerifyQuestRequest] = []
    public private(set) var username: String?
    private var attempts: [UUID: Int] = [:]
    private var completedIDs: Set<UUID> = []
    private var streak = 3

    /// `extraQuests` defaults to one more quest ~250 m from `quest`.
    public init(quest: Quest? = .sample, extraQuests: [Quest]? = nil, latency: Duration = .milliseconds(300)) {
        self.quest = quest
        self.extraQuests = extraQuests ?? quest.map { [Self.secondQuest(near: $0)] } ?? []
        self.latency = latency
    }

    public static func secondQuest(near q: Quest) -> Quest {
        Quest(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!, date: q.date, category: "tree",
              hint: "Find the big oak beside the library steps.", placeName: "Weldon Library",
              target: Geo.offset(q.target, north: 180, east: -170), geofenceRadiusM: q.geofenceRadiusM,
              foundTodayCount: 3)
    }

    public func setNextVerification(_ r: VerifyQuestResponse?) { nextVerification = r }
    public func setNextVerifyError(_ e: APIError?) { nextVerifyError = e }
    public func setFailSync(_ fail: Bool) { failSync = fail }
    public func setQuest(_ q: Quest?, extra: [Quest] = []) {
        quest = q
        extraQuests = extra
        attempts = [:]
        completedIDs = []
    }

    public var syncedTiles: [TileClear] { syncRequests.flatMap(\.tiles) }
    public var syncedPings: [LocationPing] { syncRequests.flatMap(\.pings) }
    public var syncedExpeditions: [ExpeditionRecord] { syncRequests.flatMap(\.expeditions) }

    public func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await Task.sleep(for: latency)
        if failSync { throw APIError.http(status: 503, body: "mock failure") }
        syncRequests.append(request)
        return SyncResponse(newTiles: request.tiles.count, totalTiles: syncedTiles.count)
    }

    public func questToday(at location: Coordinate) async throws -> QuestTodayResponse {
        try await Task.sleep(for: latency)
        let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        guard let q = quest else {
            return QuestTodayResponse(date: "2026-11-21", regionH3: "872ab4634ffffff", status: .noneInRegion,
                                      resetsAt: midnight, quest: nil, foundToday: 0, completedByMe: false, attemptsLeft: 0)
        }
        let entries = ([q] + extraQuests).map { q in
            QuestTodayResponse.Entry(
                quest: QuestDTO(id: q.id, category: q.category, hint: q.hint, placeName: q.placeName,
                                target: q.target, geofenceRadiusM: q.geofenceRadiusM),
                foundToday: q.foundTodayCount, completedByMe: completedIDs.contains(q.id),
                attemptsLeft: max(0, 5 - attempts[q.id, default: 0]))
        }
        let first = entries[0]
        return QuestTodayResponse(
            date: q.date, regionH3: "872ab4634ffffff", status: .active, resetsAt: midnight,
            quest: first.quest, foundToday: first.foundToday, completedByMe: first.completedByMe,
            attemptsLeft: first.attemptsLeft, quests: entries)
    }

    private func bumpFound(_ id: UUID) {
        if quest?.id == id { quest?.foundTodayCount += 1 }
        if let i = extraQuests.firstIndex(where: { $0.id == id }) { extraQuests[i].foundTodayCount += 1 }
    }

    public func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerifyQuestResponse {
        try await Task.sleep(for: latency * 3)
        verifyRequests.append(request)
        let id = request.questId
        guard quest?.id == id || extraQuests.contains(where: { $0.id == id }) else {
            throw Self.error(404, "quest_not_found", "That quest doesn't exist.")
        }
        if completedIDs.contains(id) { throw Self.error(409, "already_completed", "You already completed this quest.") }
        if attempts[id, default: 0] >= 5 { throw Self.error(429, "no_attempts_left", "You've used all 5 attempts today.") }
        if let e = nextVerifyError { nextVerifyError = nil; throw e }   // doesn't use an attempt
        attempts[id, default: 0] += 1
        let left = 5 - attempts[id, default: 0]
        if var r = nextVerification {
            nextVerification = nil
            r.attemptsLeft = left
            if r.verified { completedIDs.insert(id); bumpFound(id) }
            return r
        }
        completedIDs.insert(id)
        if completedIDs.count == 1 { streak += 1 }
        bumpFound(id)
        let completionID = UUID()
        return VerifyQuestResponse(
            verified: true, confidence: 0.93, reason: "A wooden park bench is clearly visible.", attemptsLeft: left,
            completion: .init(id: completionID, stickerUrl: URL(string: "https://example.invalid/stickers/\(completionID).png")!,
                              completedAt: Date()),
            streak: streak)
    }

    public func profile(includeTiles: Bool) async throws -> ProfileResponse {
        try await Task.sleep(for: latency)
        var p = ProfileResponse.sample
        p.username = username ?? p.username
        p.stats.tilesCleared = max(p.stats.tilesCleared, syncedTiles.count)
        p.tiles = includeTiles ? syncedTiles.map(\.h3) : nil
        return p
    }

    public func setUsername(_ name: String) async throws -> ProfileIdentity {
        try await Task.sleep(for: latency)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: "^[A-Za-z0-9_]{3,20}$", options: .regularExpression) != nil else {
            throw Self.error(400, "invalid_username", "Usernames are 3–20 letters, numbers or underscores.")
        }
        username = trimmed
        return ProfileIdentity(userId: UUID(), username: trimmed, createdAt: Date())
    }

    // Fake territory data so the leaderboard page works offline.
    public static let sampleAreas: [TerritoryArea] = [
        TerritoryArea(id: "western-campus", name: "Western University", kind: "campus", totalTiles: 858,
                      distanceFromMeM: 0, mine: AreaStats(percent: 12.4, timeS: 5_340, distanceM: 6_874)),
        TerritoryArea(id: "gibbons-park", name: "Gibbons Park", kind: "park", totalTiles: 108,
                      distanceFromMeM: 820, mine: AreaStats(percent: 3.7, timeS: 610, distanceM: 840)),
        TerritoryArea(id: "downtown-london", name: "Downtown London", kind: "neighbourhood", totalTiles: 903,
                      distanceFromMeM: 2_650, mine: AreaStats(percent: 0, timeS: 0, distanceM: 0)),
    ]

    public func leaderboardAreas(near location: Coordinate?) async throws -> LeaderboardAreasResponse {
        try await Task.sleep(for: latency)
        return LeaderboardAreasResponse(areas: Self.sampleAreas)
    }

    public func leaderboard(area: String, metric: LeaderboardMetric) async throws -> LeaderboardResponse {
        try await Task.sleep(for: latency)
        guard let a = Self.sampleAreas.first(where: { $0.id == area }) else {
            throw Self.error(404, "area_not_found", "That area doesn't exist.")
        }
        let names = ["mapmaker_ana", "trailblazer", "fogbuster", "nightowl_99", "campus_rat", "quietwalker", "leafpeeper"]
        let top: Double = metric == .percent ? 41 : metric == .time ? 21_000 : 26_000
        var entries = names.enumerated().map { i, n in
            LeaderboardEntry(rank: i + 1, name: n, value: (top * pow(0.72, Double(i))).rounded(), isMe: false)
        }
        let mineValue = a.mine.value(for: metric)
        var me: LeaderboardEntry?
        if mineValue > 0 {
            let rank = (entries.firstIndex { $0.value < mineValue } ?? entries.count) + 1
            let row = LeaderboardEntry(rank: rank, name: username ?? "Explorer 0A1B", value: mineValue, isMe: true)
            entries.insert(row, at: rank - 1)
            for i in rank..<entries.count { entries[i].rank = i + 1 }
            me = row
        }
        return LeaderboardResponse(area: .init(id: a.id, name: a.name, kind: a.kind, totalTiles: a.totalTiles),
                                   metric: metric, totalPlayers: entries.count, entries: entries, me: me)
    }

    public func cityLeaderboard(near location: Coordinate, metric: LeaderboardMetric,
                                period: LeaderboardPeriod) async throws -> CityLeaderboardResponse {
        try await Task.sleep(for: latency)
        // Shorter periods: smaller numbers, fewer players.
        let scale: Double = switch period { case .day: 0.08; case .week: 0.35; case .month: 1 }
        let base = Self.sampleAreas[0].mine
        let mine = AreaStats(percent: base.percent * scale, timeS: (base.timeS * scale).rounded(),
                             distanceM: (base.distanceM * scale).rounded())
        let names = ["mapmaker_ana", "trailblazer", "fogbuster", "nightowl_99", "campus_rat", "quietwalker", "leafpeeper"]
            .prefix(period == .day ? 3 : period == .week ? 5 : 7)
        let top: Double = (metric == .percent ? 41 : metric == .time ? 21_000 : 26_000) * scale
        var entries = names.enumerated().map { i, n in
            LeaderboardEntry(rank: i + 1, name: n, value: top * pow(0.72, Double(i)), isMe: false)
        }
        let mineValue = mine.value(for: metric)
        var me: LeaderboardEntry?
        if mineValue > 0 {
            let rank = (entries.firstIndex { $0.value < mineValue } ?? entries.count) + 1
            let row = LeaderboardEntry(rank: rank, name: username ?? "Explorer 0A1B", value: mineValue, isMe: true)
            entries.insert(row, at: rank - 1)
            for i in rank..<entries.count { entries[i].rank = i + 1 }
            me = row
        }
        let calendar = Calendar(identifier: .iso8601)
        let start = switch period {
        case .day: calendar.startOfDay(for: Date())
        case .week: calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        case .month: calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        }
        return CityLeaderboardResponse(
            area: .init(id: "western-campus", name: "Western University", kind: "campus", totalTiles: 858),
            metric: metric, period: period, periodStart: start, totalPlayers: entries.count,
            entries: entries, me: me, mine: mine)
    }

    /// A wandering walk in the unit square, different for each seed (stands in for `route_shape`).
    static func sampleShape(seed: Int) -> [FeedPost.ShapePoint] {
        let raw = (0...40).map { i -> (Double, Double) in
            let t = Double(i) / 40
            let s = Double(seed)
            return (t + 0.18 * sin(t * (5 + s) + s), 0.5 * sin(t * (2.2 + s * 0.4) + s * 1.7) + 0.25 * cos(t * 7 + s))
        }
        let xs = raw.map(\.0), ys = raw.map(\.1)
        let minX = xs.min()!, minY = ys.min()!
        let span = max(xs.max()! - minX, ys.max()! - minY)
        let padX = (1 - (xs.max()! - minX) / span) / 2, padY = (1 - (ys.max()! - minY) / span) / 2
        return raw.map { .init(x: padX + ($0.0 - minX) / span, y: padY + ($0.1 - minY) / span) }
    }

    // Fake feed so the social page works offline: a few days of sessions from other players.
    public static func sampleFeed(now: Date = Date(), myName: String? = nil) -> [FeedPost] {
        let stickerBase = "https://example.invalid/stickers/"
        func post(_ n: Int, _ name: String, isMe: Bool = false, hoursAgo: Double, minutes: Int, km: Double, tiles: Int,
                  area: (String, String)?, find: (String, String)? = nil) -> FeedPost {
            let end = now.addingTimeInterval(-hoursAgo * 3600)
            return FeedPost(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!,
                author: .init(id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!, name: name, isMe: isMe),
                startedAt: end.addingTimeInterval(-Double(minutes * 60)), endedAt: end,
                durationS: minutes * 60, distanceM: km * 1000, newTiles: tiles,
                area: area.map { .init(name: $0.0, kind: $0.1) },
                sticker: find.map { .init(url: URL(string: stickerBase + $0.0 + ".png")!, category: $0.0, placeName: $0.1) },
                routeShape: sampleShape(seed: n))
        }
        return [
            post(1, "mapmaker_ana", hoursAgo: 0.4, minutes: 42, km: 3.1, tiles: 184,
                 area: ("Western University", "campus"), find: ("bench", "University College Hill")),
            post(2, myName ?? "Explorer 0A1B", isMe: true, hoursAgo: 2, minutes: 25, km: 1.8, tiles: 96,
                 area: ("Gibbons Park", "park")),
            post(3, "trailblazer", hoursAgo: 5.5, minutes: 68, km: 5.4, tiles: 312,
                 area: ("Downtown London", "neighbourhood"), find: ("mural", "Dundas Place")),
            post(4, "fogbuster", hoursAgo: 23, minutes: 18, km: 1.2, tiles: 41, area: nil),
            post(5, "nightowl_99", hoursAgo: 27, minutes: 51, km: 3.9, tiles: 207,
                 area: ("Western University", "campus"), find: ("statue", "Middlesex College")),
            post(6, "campus_rat", hoursAgo: 49, minutes: 33, km: 2.2, tiles: 120, area: ("Western University", "campus")),
        ]
    }

    public func feed(before: Date?, limit: Int) async throws -> FeedResponse {
        try await Task.sleep(for: latency)
        let all = Self.sampleFeed(myName: username)
        let page = all.filter { before == nil || $0.endedAt < before! }.prefix(limit)
        let more = page.count == limit && all.last != page.last
        return FeedResponse(posts: Array(page), nextBefore: more ? page.last?.endedAt : nil)
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> APIError {
        .server(status: status, body: APIErrorBody(code: code, message: message, details: nil))
    }
}
