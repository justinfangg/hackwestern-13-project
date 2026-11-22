import Foundation
import Testing
@testable import FogKit

/// FogKit's wire types against the API contract's example files in docs/mocks (docs/api.md v0.2).
@Suite struct ContractTests {
    let decoder = JSONCoding.decoder

    // MARK: Responses decode

    @Test func questTodayActive() throws {
        let r = try decoder.decode(QuestTodayResponse.self, from: mockData("quest-today.200.json"))
        #expect(r.status == .active && r.foundToday == 8 && !r.completedByMe && r.attemptsLeft == 5)
        let q = try #require(r.appQuest)
        #expect(q.category == "bench" && q.placeName == "University College Hill" && q.geofenceRadiusM == 40)
        #expect(q.target == Coordinate(latitude: 43.0087, longitude: -81.2731))
        #expect(q.date == "2026-11-21" && q.title == "Find the bench")
    }

    @Test func questTodayNoQuest() throws {
        let quiet = try decoder.decode(QuestTodayResponse.self, from: mockData("quest-today.200-quiet-hours.json"))
        #expect(quiet.status == .quietHours && quiet.appQuest == nil && quiet.availableAt != nil)
        let none = try decoder.decode(QuestTodayResponse.self, from: mockData("quest-today.200-none-in-region.json"))
        #expect(none.status == .noneInRegion && none.appQuest == nil)
    }

    @Test func verifyResponses() throws {
        let ok = try decoder.decode(VerifyQuestResponse.self, from: mockData("verify-quest.200-verified.json")).result
        #expect(ok.verified && ok.attemptsLeft == 4 && ok.streak == 4)
        #expect(ok.completionID != nil && ok.stickerURL?.absoluteString.contains("/stickers/") == true)
        let no = try decoder.decode(VerifyQuestResponse.self, from: mockData("verify-quest.200-rejected.json")).result
        #expect(!no.verified && no.attemptsLeft == 3 && no.completionID == nil && no.streak == nil)
    }

    @Test func syncResponse() throws {
        let r = try decoder.decode(SyncResponse.self, from: mockData("sync.200.json"))
        #expect(r.newTiles == 3 && r.totalTiles == 138 && r.rejected.pings == 0)
    }

    @Test func profileResponses() throws {
        let p = try decoder.decode(ProfileResponse.self, from: mockData("profile.200.json"))
        #expect(p.username == "vishaal" && p.stats.currentStreak == 4 && p.tiles == nil)
        #expect(!p.stickers.isEmpty && !p.missedDays.isEmpty && p.weeklyActivity.count == 8)
        #expect(!p.expeditions.isEmpty && !p.routes.isEmpty)
        let s = p.stickers[0].sticker
        #expect(s.category == "bench" && s.questDate == "2026-11-21" && s.imageURL != nil)
        let withTiles = try decoder.decode(ProfileResponse.self, from: mockData("profile.200-include-tiles.json"))
        #expect(withTiles.tiles?.count == 138)
        let identity = try decoder.decode(ProfileIdentity.self, from: mockData("profile-post.200.json"))
        #expect(identity.username == "vishaal")
    }

    @Test func errorEnvelopes() throws {
        let tooFar = try decoder.decode(APIErrorEnvelope.self, from: mockData("verify-quest.422-too-far.json")).error
        #expect(tooFar.code == "too_far" && tooFar.details?.distanceM == 87.2 && tooFar.details?.radiusM == 40)
        for name in ["sync.413.json", "quest-today.400.json", "profile.401.json", "profile-post.409.json"] {
            let e = try decoder.decode(APIErrorEnvelope.self, from: mockData(name)).error
            #expect(!e.code.isEmpty && !e.message.isEmpty, "\(name)")
        }
    }

    // MARK: Requests encode with the contract's keys

    /// Recursively collects "path.key" names from JSON, treating arrays as their first element.
    func keyPaths(_ json: Any, prefix: String = "") -> Set<String> {
        if let dict = json as? [String: Any] {
            return dict.reduce(into: Set<String>()) { acc, kv in
                let path = prefix.isEmpty ? kv.key : "\(prefix).\(kv.key)"
                acc.insert(path)
                acc.formUnion(keyPaths(kv.value, prefix: path))
            }
        }
        if let array = json as? [Any], let first = array.first { return keyPaths(first, prefix: prefix + "[]") }
        return []
    }

    func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        keyPaths(try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(value)))
    }

    func mockKeys(_ name: String) throws -> Set<String> {
        keyPaths(try JSONSerialization.jsonObject(with: mockData(name)))
    }

    @Test func syncRequestKeys() throws {
        let exp = ExpeditionRecord(id: UUID(), startedAt: Date(), endedAt: Date(), distanceM: 364.4, newTiles: 21)
        let ping = LocationPing(expeditionID: exp.id, fix: LocationFix(coordinate: .westernCampus, timestamp: Date(),
                                                                       horizontalAccuracy: 6.5, speed: 1.4))
        let req = SyncRequest(expeditions: [exp], pings: [ping], tiles: [TileClear(h3: TileID(hex: "8b2ab4634633fff")!, clearedAt: Date())])
        #expect(try encodedKeys(req) == mockKeys("sync.request.json"))
    }

    @Test func verifyRequestKeys() throws {
        let req = VerifyQuestRequest(questId: UUID(), location: .westernCampus, accuracyM: 7.5, capturedAt: Date(),
                                     photoJpegBase64: "x", stickerPngBase64: "y")
        #expect(try encodedKeys(req) == mockKeys("verify-quest.request.json"))
    }

    @Test func setUsernameRequestKeys() throws {
        #expect(try encodedKeys(SetUsernameRequest(username: "a")) == mockKeys("profile-post.request.json"))
    }

    @Test func pingTimestampsHaveMilliseconds() throws {
        let ping = LocationPing(expeditionID: nil, fix: LocationFix(coordinate: .westernCampus,
                                                                    timestamp: Date(timeIntervalSince1970: 1.5)))
        let json = String(decoding: try JSONCoding.encoder.encode(ping), as: UTF8.self)
        #expect(json.contains(#""ts":"1970-01-01T00:00:01.500Z""#))
        #expect(json.contains(#""expedition_id":null"#))
    }

    @Test func runningExpeditionSendsNullEndedAt() throws {
        let json = String(decoding: try JSONCoding.encoder.encode(
            ExpeditionRecord(id: UUID(), startedAt: Date(), endedAt: nil, distanceM: 0, newTiles: 0)), as: UTF8.self)
        #expect(json.contains(#""ended_at":null"#))
    }
}

// MARK: - LiveFogAPI against a fake network

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                               httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LiveFogAPITests {
    func makeAPI() -> (LiveFogAPI, StubAuth) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let auth = StubAuth()
        let api = LiveFogAPI(config: BackendConfig(projectURL: URL(string: "https://ref.supabase.co")!, anonKey: "pk"),
                             auth: auth, session: URLSession(configuration: config))
        StubURLProtocol.seen = []
        return (api, auth)
    }

    @Test func callsFunctionWithHeadersAndQuery() async throws {
        let (api, _) = makeAPI()
        let body = try mockData("quest-today.200.json")
        StubURLProtocol.handler = { _ in (200, body) }
        let r = try await api.questToday(at: Coordinate(latitude: 43.0087, longitude: -81.2731))
        #expect(r.appQuest?.category == "bench")
        let req = try #require(StubURLProtocol.seen.first)
        #expect(req.url?.path == "/functions/v1/quest-today")
        #expect(req.url?.query?.contains("lat=43.0087") == true)
        #expect(req.value(forHTTPHeaderField: "apikey") == "pk")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-0")
    }

    @Test func refreshesTokenAndRetriesOnceAfter401() async throws {
        let (api, auth) = makeAPI()
        let ok = try mockData("profile.200.json"), unauthorized = try mockData("profile.401.json")
        StubURLProtocol.handler = { req in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-0" ? (401, unauthorized) : (200, ok)
        }
        let p = try await api.profile()
        #expect(p.username == "vishaal")
        #expect(auth.refreshes == 1 && StubURLProtocol.seen.count == 2)
        #expect(StubURLProtocol.seen[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-token-1")
    }

    @Test func parsesErrorEnvelope() async throws {
        let (api, _) = makeAPI()
        let tooFar = try mockData("verify-quest.422-too-far.json")
        StubURLProtocol.handler = { _ in (422, tooFar) }
        do {
            _ = try await api.verifyQuest(VerifyQuestRequest(questId: UUID(), location: .westernCampus, accuracyM: 5,
                                                             capturedAt: Date(), photoJpegBase64: "", stickerPngBase64: ""))
            Issue.record("expected an error")
        } catch let e as APIError {
            #expect(e.code == "too_far" && e.status == 422)
        }
    }
}

// MARK: - Sync batching rules (docs/api.md §2)

@Suite @MainActor struct SyncRulesTests {
    @Test func pingsForRunningExpeditionCarryItsRecord() async {
        let api = MockFogAPI(latency: .zero)
        let queue = SyncQueue(api: api, store: nil)
        let active = ExpeditionRecord(id: UUID(), startedAt: Date(), endedAt: nil, distanceM: 12, newTiles: 3)
        queue.activeExpedition = { active }
        queue.enqueue(ping: LocationPing(expeditionID: active.id, fix: fix(.westernCampus, at: Date())))
        await queue.flush()
        #expect(await api.syncedExpeditions == [active])
        #expect(queue.pendingCount == 0)
    }

    @Test func endedExpeditionStaysUntilItsLastPingIsSent() async {
        let api = MockFogAPI(latency: .zero)
        let queue = SyncQueue(api: api, store: nil)
        queue.maxPingsPerBatch = 2
        let summary = ExpeditionSummary.sample
        for i in 0..<5 {
            queue.enqueue(ping: LocationPing(expeditionID: summary.id,
                                             fix: fix(.westernCampus, at: Date(timeIntervalSince1970: Double(i)))))
        }
        queue.enqueue(expedition: summary)
        await queue.flush()
        let requests = await api.syncRequests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.expeditions.map(\.id) == [summary.id] })   // record in every batch
        #expect(queue.pendingCount == 0)
    }
}

// MARK: - Anonymous sign-in against a fake Supabase Auth

/// Separate fake network so these tests don't share state with LiveFogAPITests (suites run in parallel).
final class AuthStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                               httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AnonymousAuthTests {
    static func tokenJSON(_ n: Int, user: UUID) -> Data {
        Data(#"{"access_token":"access-\#(n)","token_type":"bearer","expires_in":3600,"refresh_token":"refresh-\#(n)","user":{"id":"\#(user.uuidString)"}}"#.utf8)
    }

    func makeAuth(store: InMemorySessionStore = InMemorySessionStore()) -> SupabaseAnonymousAuth {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthStubURLProtocol.self]
        AuthStubURLProtocol.seen = []
        return SupabaseAnonymousAuth(config: BackendConfig(projectURL: URL(string: "https://ref.supabase.co")!, anonKey: "pk"),
                                     store: store, urlSession: URLSession(configuration: config))
    }

    @Test func signsUpOnceThenUsesCachedToken() async throws {
        let user = UUID()
        AuthStubURLProtocol.handler = { _ in (200, Self.tokenJSON(1, user: user)) }
        let store = InMemorySessionStore()
        let auth = makeAuth(store: store)
        #expect(try await auth.accessToken() == "access-1")
        #expect(try await auth.accessToken() == "access-1")
        #expect(AuthStubURLProtocol.seen.count == 1)
        #expect(AuthStubURLProtocol.seen[0].url?.path == "/auth/v1/signup")
        #expect(AuthStubURLProtocol.seen[0].value(forHTTPHeaderField: "apikey") == "pk")
        #expect(await auth.userID == user && store.load()?.refreshToken == "refresh-1")
    }

    @Test func forceRefreshUsesRefreshToken() async throws {
        let user = UUID()
        let existing = SupabaseAnonymousAuth.Session(accessToken: "old", refreshToken: "refresh-0",
                                                     expiresAt: Date().addingTimeInterval(3600), userID: user)
        AuthStubURLProtocol.handler = { _ in (200, Self.tokenJSON(2, user: user)) }
        let auth = makeAuth(store: InMemorySessionStore(existing))
        #expect(try await auth.accessToken() == "old")                    // restored from the store
        #expect(try await auth.accessToken(forceRefresh: true) == "access-2")
        let req = try #require(AuthStubURLProtocol.seen.first)
        #expect(req.url?.path == "/auth/v1/token" && req.url?.query == "grant_type=refresh_token")
    }

    @Test func rejectedRefreshSignsUpAgain() async throws {
        let user = UUID()
        let expired = SupabaseAnonymousAuth.Session(accessToken: "old", refreshToken: "dead",
                                                    expiresAt: Date().addingTimeInterval(-10), userID: UUID())
        AuthStubURLProtocol.handler = { req in
            req.url?.path == "/auth/v1/token" ? (400, Data(#"{"error":"invalid_grant"}"#.utf8)) : (200, Self.tokenJSON(3, user: user))
        }
        let auth = makeAuth(store: InMemorySessionStore(expired))
        #expect(try await auth.accessToken() == "access-3")
        #expect(AuthStubURLProtocol.seen.map { $0.url!.path } == ["/auth/v1/token", "/auth/v1/signup"])
        #expect(await auth.userID == user)
    }
}

// MARK: - Leaderboard (§7)

@Suite struct LeaderboardContractTests {
    @Test func decodesAreasAndRanking() throws {
        let areas = try JSONCoding.decoder.decode(LeaderboardAreasResponse.self, from: mockData("leaderboard-areas.200.json")).areas
        #expect(areas.map(\.kind) == ["campus", "park", "neighbourhood"])
        #expect(areas[0].mine.value(for: .distance) == 6874.2 && areas[0].distanceFromMeM == 0)
        let board = try JSONCoding.decoder.decode(LeaderboardResponse.self, from: mockData("leaderboard.200.json"))
        #expect(board.metric == .percent && board.entries.count == 4 && board.me?.rank == 3)
        #expect(board.entries.filter(\.isMe).map(\.name) == ["vishaal"])
        let e = try JSONCoding.decoder.decode(APIErrorEnvelope.self, from: mockData("leaderboard.404.json")).error
        #expect(e.code == "area_not_found")
    }
}

@Suite @MainActor struct LeaderboardModelTests {
    @Test func loadsNearestAreaThenSwitchesMetricAndArea() async {
        let model = LeaderboardModel(api: MockFogAPI(latency: .zero))
        await model.load(near: .westernCampus)
        #expect(model.areas.count == 3 && model.selectedArea?.id == "western-campus")
        #expect(model.board?.metric == .percent && model.board?.me?.isMe == true)
        await model.select(metric: .distance)
        #expect(model.board?.metric == .distance && model.board?.me?.value == 6_874)
        await model.select(area: "downtown-london")
        #expect(model.board?.area.id == "downtown-london" && model.board?.me == nil)   // no score there yet
        #expect(model.lastError == nil && !model.isLoading)
    }

    @Test func rememberedMetricIsUsedOnLoad() async {
        let model = LeaderboardModel(api: MockFogAPI(latency: .zero))
        await model.load(near: nil, metric: .time)
        #expect(model.board?.metric == .time)
    }
}
