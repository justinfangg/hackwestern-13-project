import Foundation
import FogCore

/// Supabase project settings. Fill in from the Supabase dashboard (Project Settings → API).
/// The anon key is safe to ship in the app; never put the Tiger Data connection string here.
public struct BackendConfig: Sendable {
    public var projectURL: URL
    public var anonKey: String
    public var stickerBucket: String

    public init(projectURL: URL, anonKey: String, stickerBucket: String = "stickers") {
        self.projectURL = projectURL
        self.anonKey = anonKey
        self.stickerBucket = stickerBucket
    }
}

public enum APIError: Error, Equatable {
    case notSignedIn
    case http(status: Int, body: String)
    case invalidResponse
}

/// The four Edge Functions (PRD §10.1). `LiveFogAPI` calls them; `MockFogAPI` fakes them.
public protocol FogAPI: Sendable {
    func sync(_ request: SyncRequest) async throws -> SyncResponse
    func questToday(at location: Coordinate) async throws -> QuestTodayResponse
    func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerificationResult
    func profile() async throws -> ProfileResponse
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

    public func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerificationResult {
        try await call("verify-quest", method: "POST", body: request)
    }

    public func profile() async throws -> ProfileResponse {
        try await call("profile")
    }

    // MARK: Plumbing

    private struct Empty: Encodable {}

    private func call<Response: Decodable>(_ function: String, method: String = "GET",
                                           query: [URLQueryItem] = []) async throws -> Response {
        try await call(function, method: method, query: query, body: Optional<Empty>.none)
    }

    private func call<Body: Encodable, Response: Decodable>(_ function: String, method: String = "GET",
                                                            query: [URLQueryItem] = [],
                                                            body: Body?) async throws -> Response {
        var components = URLComponents(url: config.projectURL.appendingPathComponent("functions/v1/\(function)"),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCoding.encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONCoding.decoder.decode(Response.self, from: data)
    }
}

/// In-memory fake backend so the app runs end to end before the Edge Functions exist.
public actor MockFogAPI: FogAPI {
    public var quest: Quest?
    /// Verification outcome to return; defaults to success.
    public var nextVerification: VerificationResult
    public var latency: Duration
    public private(set) var syncedTiles: [TileClear] = []
    public private(set) var syncedPings: [LocationPing] = []
    public private(set) var syncedExpeditions: [ExpeditionRecord] = []
    public private(set) var verifyCalls = 0
    public var failSync = false

    public init(quest: Quest? = .sample,
                nextVerification: VerificationResult = .init(verified: true, confidence: 0.93,
                                                             reason: "A wooden park bench is clearly visible.",
                                                             attemptsRemaining: 4),
                latency: Duration = .milliseconds(300)) {
        self.quest = quest
        self.nextVerification = nextVerification
        self.latency = latency
    }

    public func setNextVerification(_ r: VerificationResult) { nextVerification = r }
    public func setFailSync(_ fail: Bool) { failSync = fail }
    public func setQuest(_ q: Quest?) { quest = q }

    public func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await Task.sleep(for: latency)
        if failSync { throw APIError.http(status: 503, body: "mock failure") }
        syncedTiles += request.tiles
        syncedPings += request.pings
        syncedExpeditions += request.expeditions
        return SyncResponse(acceptedTiles: request.tiles.count, acceptedPings: request.pings.count)
    }

    public func questToday(at location: Coordinate) async throws -> QuestTodayResponse {
        try await Task.sleep(for: latency)
        return QuestTodayResponse(quest: quest)
    }

    public func verifyQuest(_ request: VerifyQuestRequest) async throws -> VerificationResult {
        try await Task.sleep(for: latency * 3)
        verifyCalls += 1
        if nextVerification.verified { quest?.foundTodayCount += 1 }
        return nextVerification
    }

    public func profile() async throws -> ProfileResponse {
        try await Task.sleep(for: latency)
        var p = ProfileResponse.sample
        p.stats.tilesCleared = max(p.stats.tilesCleared, syncedTiles.count)
        return p
    }
}
