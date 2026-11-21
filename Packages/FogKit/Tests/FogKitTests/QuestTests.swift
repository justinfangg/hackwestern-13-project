import Foundation
import Testing
@testable import FogKit

@Suite @MainActor struct QuestCaptureTests {
    let quest = Quest.sample

    func makeModel(_ results: [Result<VerificationResult, Error>]) -> (QuestCaptureModel, StubVerifier) {
        let verifier = StubVerifier(results)
        let model = QuestCaptureModel(verifier: verifier, extractor: PassthroughExtractor(), remoteStorage: nil,
                                      localStorage: LocalStickerStorage(directory: tempDirectory()), location: nil)
        model.setQuest(quest)
        return (model, verifier)
    }

    func near(_ metres: Double) -> Coordinate { Geo.offset(quest.target, north: metres, east: 0) }

    static let ok = VerificationResult(verified: true, confidence: 0.9, reason: "bench", attemptsRemaining: 4)

    @Test func unlocksInsideFortyMetresWithHysteresis() {
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

    @Test func captureIgnoredWhileLocked() async {
        let (m, v) = makeModel([.success(Self.ok)])
        m.updateLocation(near(200))
        await m.capture(solidImage())
        #expect(v.calls == 0 && m.state == .locked)
    }

    @Test func successCollectsStickerAndNotifies() async {
        let (m, _) = makeModel([.success(Self.ok)])
        var found: Sticker?
        m.onSuccess = { s, _ in found = s }
        m.updateLocation(near(10))
        await m.capture(solidImage())
        guard case .success(let sticker) = m.state else { Issue.record("state \(m.state)"); return }
        #expect(found == sticker)
        #expect(sticker.category == "bench")
        #expect(sticker.localImageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func lowConfidenceIsRejectedWithRetry() async {
        let weak = VerificationResult(verified: true, confidence: 0.5, reason: "Blurry", attemptsRemaining: 3)
        let (m, _) = makeModel([.success(weak), .success(Self.ok)])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        #expect(m.state == .rejected(reason: "Blurry", attemptsRemaining: 3))
        m.retry()
        #expect(m.state == .ready)
        await m.capture(solidImage())
        if case .success = m.state {} else { Issue.record("expected success, got \(m.state)") }
    }

    @Test func noAttemptsLeft() async {
        let no = VerificationResult(verified: false, confidence: 0.1, reason: "No bench", attemptsRemaining: 0)
        let (m, _) = makeModel([.success(no)])
        m.updateLocation(near(10))
        await m.capture(solidImage())
        #expect(m.state == .outOfAttempts)
    }

    @Test func networkErrorAllowsRetry() async {
        let (m, _) = makeModel([.failure(APIError.invalidResponse)])
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
        let tilesBeforeReveal = explorer.cleared.count

        // Capture → mock verification succeeds → Quest Reveal clears 150 m, sticker attached.
        await services.questCapture.capture(solidImage())
        guard case .success = services.questCapture.state else {
            Issue.record("state \(services.questCapture.state)"); return
        }
        #expect(explorer.cleared.count > tilesBeforeReveal + 100)
        #expect(services.profile.stickers.count == 1)
        #expect(services.quests.today?.foundTodayCount == quest.foundTodayCount + 1)

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
