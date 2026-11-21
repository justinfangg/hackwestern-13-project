import Foundation
import SwiftUI
import Testing
@testable import FogKit

@Suite @MainActor struct ExpeditionTests {
    @Test func tracksDistanceTilesAndSegments() {
        let location = LocationService()
        let explorer = GridExplorer()
        let clock = TestClock()
        let expeditions = ExpeditionManager(location: nil, clock: clock.closure)
        let pipeline = ExplorationPipeline(location: location, explorer: explorer, expeditions: expeditions)
        var cleared: [TileID] = [], pings: [LocationPing] = []
        pipeline.onTilesCleared = { cleared += $0 }
        pipeline.onPing = { pings.append($0) }
        var ended: ExpeditionSummary?
        expeditions.onEnd = { ended = $0 }

        expeditions.start()
        var c = Coordinate.westernCampus
        for _ in 0..<10 {
            location.handle(fix(c, at: clock.now))
            c = Geo.offset(c, north: 10, east: 0)
            clock.advance(7)
        }
        // GPS jump of 1 km: rejected as too fast three times, then a new segment.
        let far = Geo.offset(c, north: 1_000, east: 0)
        for i in 0..<3 { location.handle(fix(Geo.offset(far, north: Double(i) * 5, east: 0), at: clock.now)); clock.advance(1) }

        let summary = expeditions.end()
        #expect(summary == ended)
        #expect(abs(summary!.distanceMeters - 90) < 1)  // the jump is not counted
        #expect(summary!.segments.count == 2)
        #expect(summary!.newTiles == cleared.count && summary!.newTiles > 0)
        #expect(pings.count == 11 && pings.allSatisfy { $0.expeditionID == summary!.id })
        #expect(summary!.duration == 73)
    }

    @Test func fogClearsWithoutAnExpedition() {
        let location = LocationService()
        let explorer = GridExplorer()
        let expeditions = ExpeditionManager(location: nil)
        let pipeline = ExplorationPipeline(location: location, explorer: explorer, expeditions: expeditions)
        location.handle(fix(.westernCampus, at: Date()))
        #expect(!explorer.cleared.isEmpty)
        #expect(expeditions.active == nil)
        _ = pipeline
    }

    @Test func historyPersists() {
        let dir = tempDirectory()
        let history = ExpeditionHistory(store: JSONFileStore(filename: "e.json", directory: dir))
        history.add(.sample)
        let reloaded = ExpeditionHistory(store: JSONFileStore(filename: "e.json", directory: dir))
        #expect(reloaded.expeditions.map(\.id) == [ExpeditionSummary.sample.id])
    }

    @Test func rendersShareCardToStoryPNG() {
        let png = ShareImage.render(Text("Expedition").padding())
        #expect(png != nil)
        #expect(png?.cgImage.width == 1080 && png?.cgImage.height == 1920)
    }
}

@Suite @MainActor struct SyncQueueTests {
    @Test func flushesBatchesAndPersistsOnFailure() async {
        let api = MockFogAPI(latency: .zero)
        let dir = tempDirectory()
        let store = JSONFileStore<SyncQueue.Pending>(filename: "p.json", directory: dir)
        let queue = SyncQueue(api: api, store: store)
        queue.maxTilesPerBatch = 2

        queue.enqueue(tiles: [TileID(1), TileID(2), TileID(3)])
        queue.enqueue(ping: LocationPing(expeditionID: nil, fix: fix(.westernCampus, at: Date())))
        queue.enqueue(expedition: .sample)

        await api.setFailSync(true)
        await queue.flush()
        #expect(queue.pendingCount == 5)
        #expect(queue.lastError != nil)
        #expect(SyncQueue(api: api, store: store).pendingCount == 5) // survived "relaunch"

        await api.setFailSync(false)
        await queue.flush()
        #expect(queue.pendingCount == 0)
        #expect(await api.syncedTiles.map(\.tile) == [TileID(1), TileID(2), TileID(3)])
        #expect(await api.syncedExpeditions.count == 1)
    }
}
