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
    /// Next verification outcome; nil = verified.
    public var nextVerification: VerifyQuestResponse?
    /// Next verification error (e.g. `verifier_unavailable`), checked before `nextVerification`.
    public var nextVerifyError: APIError?
    public var latency: Duration
    public var failSync = false
    public private(set) var syncRequests: [SyncRequest] = []
    public private(set) var verifyRequests: [VerifyQuestRequest] = []
    public private(set) var username: String?
    private var attemptsUsed = 0
    private var completed = false
    private var streak = 3

    public init(quest: Quest? = .sample, latency: Duration = .milliseconds(300)) {
        self.quest = quest
        self.latency = latency
    }

    public func setNextVerification(_ r: VerifyQuestResponse?) { nextVerification = r }
    public func setNextVerifyError(_ e: APIError?) { nextVerifyError = e }
    public func setFailSync(_ fail: Bool) { failSync = fail }
    public func setQuest(_ q: Quest?) { quest = q; attemptsUsed = 0; completed = false }

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
        return QuestTodayResponse(
            date: q.date, regionH3: "872ab4634ffffff", status: .active, resetsAt: midnight,
            quest: QuestDTO(id: q.id, category: q.category, hint: q.hint, placeName: q.placeName,
                            target: q.target, geofenceRadiusM: q.geofenceRadiusM),
            foundToday: q.foundTodayCount, completedByMe: completed, attemptsLeft: max(0, 5 - attemptsUsed))
    }

    public func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerifyQuestResponse {
        try await Task.sleep(for: latency * 3)
        verifyRequests.append(request)
        if completed { throw Self.error(409, "already_completed", "You already completed this quest.") }
        if attemptsUsed >= 5 { throw Self.error(429, "no_attempts_left", "You've used all 5 attempts today.") }
        if let e = nextVerifyError { nextVerifyError = nil; throw e }   // doesn't use an attempt
        attemptsUsed += 1
        let left = 5 - attemptsUsed
        if var r = nextVerification {
            nextVerification = nil
            r.attemptsLeft = left
            if r.verified { completed = true; quest?.foundTodayCount += 1 }
            return r
        }
        completed = true
        streak += 1
        quest?.foundTodayCount += 1
        let id = UUID()
        return VerifyQuestResponse(
            verified: true, confidence: 0.93, reason: "A wooden park bench is clearly visible.", attemptsLeft: left,
            completion: .init(id: id, stickerUrl: URL(string: "https://example.invalid/stickers/\(id).png")!,
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

    static func error(_ status: Int, _ code: String, _ message: String) -> APIError {
        .server(status: status, body: APIErrorBody(code: code, message: message, details: nil))
    }
}
