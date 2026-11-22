import Foundation
import Testing
@testable import FogKit

@Suite @MainActor struct QuestCaptureTests {
    let quest = Quest.sample

    func makeModel(_ results: [Result<VerificationResult, Error>]) -> (QuestCaptureModel, StubVerifier) {
        let verifier = StubVerifier(results)
        let model = QuestCaptureModel(verifier: verifier, extractor: PassthroughExtractor(),
                                      stickerCache: LocalStickerStorage(directory: tempDirectory()), location: nil)
        model.setQuest(quest)
        return (model, verifier)
    }

    func near(_ metres: Double) -> Coordinate { Geo.offset(quest.target, north: metres, east: 0) }

    static let ok = VerificationResult(verified: true, confidence: 0.9, reason: "bench", attemptsLeft: 4,
                                       completionID: UUID(), stickerURL: URL(string: "https://x.invalid/s.png"),
                                       completedAt: Date(), streak: 5)

    static func serverError(_ status: Int, _ code: String, distance: Double? = nil) -> APIError {
        .server(status: status, body: APIErrorBody(code: code, message: code,
                                                   details: distance.map { .init(distanceM: $0, radiusM: 40, fields: nil) }))
    }

    @Test func unlocksInsideGeofenceWithHysteresis() {
        let (m, _) = makeModel([])
        m.updateLocation(near(200))
        #expect(m.state == .locked && !m.canCapture)
        #expect(abs(m.distanceToTarget! - 200) < 0.5)
        m.updateLocation(near(39))
        #expect(m.state == .ready)
        m.updateLocation(near(45))   // between 40 and 50: stays unlocked
        #expect(m.state == .ready)
        m.updateLocation(near(60))
        #expect(m.state == .locked)
    }

    @Test func startsCompletedOrOutOfAttemptsFromQuestToday() {
        let a = QuestCaptureModel(verifier: StubVerifier([]), location: nil)
        a.setQuest(quest, completedByMe: true)
        #expect(a.state == .alreadyCompleted)
        let b = QuestCaptureModel(verifier: StubVerifier([]), location: nil)
        b.setQuest(quest, attemptsLeft: 0)
        #expect(b.state == .outOfAttempts)
    }

    @Test func captureIgnoredWhileLocked() async {
        let (m, v) = makeModel([.success(Self.ok)])
        m.updateLocation(near(200))
        await m.capture(solidImage())
        #expect(v.calls == 0 && m.state == .locked)
    }

    @Test func successCollectsServerStickerAndNotifies() async {
        let (m, v) = makeModel([.success(Self.ok)])
        var found: Sticker?
        m.onSuccess = { s, _ in found = s }
        m.updateLocation(near(10), accuracy: 7.5)
        await m.capture(solidImage())
        guard case .success(let sticker) = m.state else { Issue.record("state \(m.state)"); return }
        #expect(found == sticker)
        #expect(sticker.id == Self.ok.completionID && sticker.imageURL == Self.ok.stickerURL)
        #expect(sticker.location == quest.target)
        #expect(sticker.localImageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(m.streak == 5 && m.attemptsLeft == 4)
        // The request carries the photo, the cut-out sticker, and the GPS accuracy.
        let req = try! #require(v.requests.first)
        #expect(req.accuracyM == 7.5 && !req.photoJpegBase64.isEmpty && !req.stickerPngBase64.isEmpty)
    }

    @Test func serverVerdictIsFinalNoClientThreshold() async {
        // Low confidence but verified by the server: accept (docs/api.md §4).
        var lowButVerified = Self.ok
        lowButVerified.confidence = 0.4
        let (m, _) = makeModel([.success(lowButVerified)])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        if case .success = m.state {} else { Issue.record("expected success, got \(m.state)") }
    }

    @Test func rejectedAllowsRetry() async {
        let no = VerificationResult(verified: false, confidence: 0.3, reason: "Looks like a screen", attemptsLeft: 3)
        let (m, _) = makeModel([.success(no), .success(Self.ok)])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        #expect(m.state == .rejected(reason: "Looks like a screen", attemptsLeft: 3))
        m.retry()
        #expect(m.state == .ready)
        await m.capture(solidImage())
        if case .success = m.state {} else { Issue.record("expected success, got \(m.state)") }
    }

    @Test func noAttemptsLeftAfterRejection() async {
        let no = VerificationResult(verified: false, confidence: 0.1, reason: "No bench", attemptsLeft: 0)
        let (m, _) = makeModel([.success(no)])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        #expect(m.state == .outOfAttempts)
    }

    @Test func mapsServerErrorCodesToStates() async {
        let cases: [(APIError, QuestCaptureModel.State)] = [
            (Self.serverError(422, "too_far", distance: 87.2), .tooFar(distanceMeters: 87.2)),
            (Self.serverError(409, "already_completed"), .alreadyCompleted),
            (Self.serverError(429, "no_attempts_left"), .outOfAttempts),
        ]
        for (error, expected) in cases {
            let (m, _) = makeModel([.failure(error)])
            m.updateLocation(near(10))
            await m.capture(solidImage())
            #expect(m.state == expected)
        }
    }

    @Test func verifierUnavailableIsRetryable() async {
        let (m, _) = makeModel([.failure(Self.serverError(502, "verifier_unavailable")), .success(Self.ok)])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        guard case .error(let message) = m.state else { Issue.record("state \(m.state)"); return }
        #expect(message.contains("didn't use an attempt"))
        m.retry()
        #expect(m.state == .ready)
    }

    @Test func staleQuestTriggersRefetch() async {
        let (m, _) = makeModel([.failure(Self.serverError(422, "not_todays_quest"))])
        var stale = false
        m.onQuestStale = { stale = true }
        m.updateLocation(near(10))
        await m.capture(solidImage())
        #expect(stale)
    }

    @Test func networkErrorAllowsRetry() async {
        let (m, _) = makeModel([.failure(URLError(.notConnectedToInternet))])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        guard case .error = m.state else { Issue.record("state \(m.state)"); return }
        m.retry()
        #expect(m.state == .ready)
    }
}

@Suite struct StickerTests {
    @Test func circularCropIsSquareWithTransparentCorners() {
        let out = VisionStickerExtractor.circularCrop(solidImage(width: 100, height: 60))
        #expect(out.width == 48 && out.height == 48)
        #expect(out.alphaInfo == .premultipliedLast)
    }

    @Test func jpegIsDownscaledTo1024() {
        let big = solidImage(width: 3000, height: 2000)
        let data = ImageEncoding.jpeg(big)!
        let decoded = ImageEncoding.uprightImage(from: data, maxDimension: 4096)!
        #expect(decoded.width == 1024 && decoded.height == 682)
    }
}

@Suite @MainActor struct FogServicesTests {
    @Test func endToEndWithMockBackend() async throws {
        let defaults = UserDefaults(suiteName: "FogKitTests-\(UUID())")!
        let explorer = GridExplorer()
        let services = FogServices(explorer: explorer, auth: nil, backend: nil,
                                   debug: DebugSettings(defaults: defaults), storageDirectory: tempDirectory())
        #expect(services.usingMockBackend)

        // Quest loads from the mock backend.
        await services.refreshQuest()
        let quest = try #require(services.quests.today)
        #expect(services.questCapture.state == .locked)

        // Walk to the quest during an expedition.
        services.expeditions.start()
        let start = Geo.offset(quest.target, north: -60, east: 0)
        let t0 = Date()
        for i in 0...6 {
            services.location.handle(fix(Geo.offset(start, north: Double(i) * 10, east: 0), at: t0 + Double(i) * 7))
        }
        #expect(services.questCapture.state == .ready)
        let tilesBeforeCapture = explorer.cleared.count

        // Capture → mock verification succeeds → sticker attached. No extra fog clears at the quest.
        await services.questCapture.capture(solidImage())
        guard case .success = services.questCapture.state else {
            Issue.record("state \(services.questCapture.state)"); return
        }
        #expect(explorer.cleared.count == tilesBeforeCapture)
        #expect(services.profile.stickers.count == 1)
        #expect(services.quests.today?.foundTodayCount == quest.foundTodayCount + 1)
        #expect(services.quests.completedByMe)

        let summary = try #require(services.expeditions.end())
        #expect(summary.sticker != nil)
        #expect(summary.newTiles == explorer.cleared.count)
        #expect(services.history.expeditions.count == 1)

        await services.sync.flush()
        #expect(services.sync.pendingCount == 0)
    }

    @Test func debugToggleSwitchesToSimulator() async {
        let defaults = UserDefaults(suiteName: "FogKitTests-\(UUID())")!
        let debug = DebugSettings(defaults: defaults)
        let services = FogServices(explorer: GridExplorer(), auth: nil, backend: nil, debug: debug,
                                   storageDirectory: tempDirectory())
        #expect(!services.location.isSimulating)
        debug.isSimulatorEnabled = true
        await Task.yield(); await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(services.location.isSimulating)
    }
}

@Suite @MainActor struct DebugParticipantTests {
    @Test func fakeParticipantsOverrideTheRealCountAndPersist() {
        let defaults = UserDefaults(suiteName: "debug-participants-\(UUID().uuidString)")!
        let debug = DebugSettings(defaults: defaults)
        #expect(debug.participantCount(real: 2) == 2)

        debug.fakeParticipants = true
        #expect(debug.participantCount(real: 0) == DebugSettings.fakeParticipantCount)
        #expect(DebugSettings(defaults: defaults).fakeParticipants)
    }
}

@Suite @MainActor struct RestoreFogTests {
    @Test func freshInstallRestoresTilesFromServer() async throws {
        let api = MockFogAPI(latency: .zero)
        let serverTiles = [TileID(hex: "8b2ab4634633fff")!, TileID(hex: "8b2ab4634613fff")!]
        _ = try await api.sync(SyncRequest(expeditions: [], pings: [],
                                           tiles: serverTiles.map { TileClear(h3: $0, clearedAt: Date()) }))
        let explorer = GridExplorer()
        let services = FogServices(explorer: explorer, auth: nil, backend: nil,
                                   debug: DebugSettings(defaults: UserDefaults(suiteName: "restore-\(UUID())")!),
                                   storageDirectory: tempDirectory(), api: api)
        await services.restoreFog()
        #expect(services.restoredTileCount == 2)
        #expect(Set(serverTiles).isSubset(of: explorer.cleared))
        #expect(services.sync.pendingCount == 0)    // restored tiles aren't synced back
        await services.restoreFog()
        #expect(services.restoredTileCount == 0)    // already on the device
    }
}

// MARK: - Several quests a day

@Suite @MainActor struct MultipleQuestTests {
    @Test func decodesEveryQuestAndFallsBackToOne() throws {
        let multi = try JSONCoding.decoder.decode(QuestTodayResponse.self, from: mockData("quest-today.200-multiple.json"))
        #expect(multi.appQuests.map(\.quest.category) == ["bench", "tree"])
        #expect(multi.appQuests[1].completedByMe && multi.appQuests[1].attemptsLeft == 4)
        #expect(multi.appQuests[1].quest.foundTodayCount == 3 && multi.appQuests[1].quest.placeName == "Weldon Library")
        // Older servers send only `quest`.
        let single = try JSONCoding.decoder.decode(QuestTodayResponse.self, from: mockData("quest-today.200.json"))
        #expect(single.quests == nil && single.appQuests.count == 1 && single.appQuests[0].quest.foundTodayCount == 8)
    }

    @Test func picksTheFirstUnfinishedQuestAndKeepsTheChoice() async throws {
        let first = Quest.sample, second = MockFogAPI.secondQuest(near: .sample)
        let api = MockFogAPI(quest: first, extraQuests: [second], latency: .zero)
        let service = QuestService(api: api)
        await service.refresh(at: .westernCampus)
        #expect(service.options.count == 2 && service.today?.id == first.id)

        service.select(second.id)
        #expect(service.today?.id == second.id && service.attemptsLeft == 5 && !service.completedByMe)
        service.select(UUID())   // unknown id: ignored
        #expect(service.today?.id == second.id)

        await service.refresh(at: .westernCampus)   // a refresh keeps the player's pick
        #expect(service.today?.id == second.id)

        service.recordOwnFind()
        #expect(service.completedByMe && service.options[1].quest.foundTodayCount == second.foundTodayCount + 1)
        #expect(!service.options[0].completedByMe)
    }

    @Test func selectingAQuestRetargetsTheCapture() async throws {
        let defaults = UserDefaults(suiteName: "FogKitTests-\(UUID())")!
        let services = FogServices(explorer: GridExplorer(), auth: nil, backend: nil,
                                   debug: DebugSettings(defaults: defaults), storageDirectory: tempDirectory(),
                                   api: MockFogAPI(latency: .zero))
        await services.refreshQuest()
        let second = try #require(services.quests.options.last?.quest)
        services.selectQuest(second.id)
        #expect(services.questCapture.quest?.id == second.id && services.questCapture.state == .locked)

        // Walk to the second quest and verify it: completes that one only.
        services.expeditions.start(kind: .quest)
        let start = Geo.offset(second.target, north: -60, east: 0)
        let t0 = Date()
        for i in 0...6 {
            services.location.handle(fix(Geo.offset(start, north: Double(i) * 10, east: 0), at: t0 + Double(i) * 7))
        }
        #expect(services.questCapture.state == .ready)
        await services.questCapture.capture(solidImage())
        guard case .success = services.questCapture.state else {
            Issue.record("state \(services.questCapture.state)"); return
        }
        await services.refreshQuest()
        #expect(services.quests.options.map(\.completedByMe) == [false, true])
        #expect(services.quests.today?.id == second.id)
    }
}
