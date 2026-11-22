import Foundation
import Testing
@testable import FogKit

@Suite struct GeoTests {
    @Test func oneDegreeOfLatitudeIsAbout111km() {
        let d = Geo.distance(Coordinate(latitude: 43, longitude: -81), Coordinate(latitude: 44, longitude: -81))
        #expect(abs(d - 111_195) < 200)
    }

    @Test func offsetMovesTheRequestedDistance() {
        let moved = Geo.offset(.westernCampus, north: 30, east: 40)
        #expect(abs(Geo.distance(.westernCampus, moved) - 50) < 0.5)
    }
}

@Suite struct TileIDTests {
    @Test func encodesAsHexStringNotNumber() throws {
        let tile = TileID(0x8b2a_b2d9_a54a_ffff) // larger than 2^53
        let json = String(decoding: try JSONEncoder().encode([tile]), as: UTF8.self)
        #expect(json == #"["8b2ab2d9a54affff"]"#)
        #expect(try JSONDecoder().decode([TileID].self, from: Data(json.utf8)) == [tile])
    }
}

@Suite @MainActor struct GridExplorerTests {
    @Test func clearsVisionRadiusOnceAndResets() {
        let grid = GridExplorer()
        let first = grid.clearTiles(around: [.westernCampus])
        #expect(first.count >= 5)          // ~30 m radius over 20 m cells
        #expect(grid.clearTiles(around: [.westernCampus]).isEmpty)
        #expect(grid.clearArea(center: .westernCampus, radiusMeters: 150).count > 100)
        grid.resetAll()
        #expect(grid.cleared.isEmpty)
    }
}

@Suite struct JSONContractTests {
    @Test func usesSnakeCaseAndMillisecondDates() throws {
        let req = VerifyQuestRequest(questId: UUID(), location: .westernCampus, accuracyM: 5,
                                     capturedAt: Date(timeIntervalSince1970: 0.25),
                                     photoJpegBase64: "abc", stickerPngBase64: "def")
        let json = String(decoding: try JSONCoding.encoder.encode(req), as: UTF8.self)
        #expect(json.contains("\"quest_id\""))
        #expect(json.contains("\"photo_jpeg_base64\""))
        #expect(json.contains("\"captured_at\":\"1970-01-01T00:00:00.250Z\""))
    }

    @Test func decodesWholeAndFractionalSecondDates() throws {
        struct D: Decodable { var at: Date }
        #expect(try JSONCoding.decoder.decode(D.self, from: Data(#"{"at":"2026-11-21T12:00:00Z"}"#.utf8)).at.timeIntervalSince1970 > 0)
        let d = try JSONCoding.decoder.decode(D.self, from: Data(#"{"at":"2026-11-21T12:00:00.123Z"}"#.utf8))
        #expect(d.at.timeIntervalSince1970 > 0)
    }
}

@Suite struct StickerPersistenceTests {
    /// The snake_case round trip used by every JSON file and the API must keep the URLs and quest id
    /// (keys like "image_url" convert back to "imageUrl", not "imageURL").
    @Test func stickerKeepsURLsThroughSnakeCaseRoundTrip() throws {
        let sticker = Sticker(questID: UUID(), category: "chair", questDate: "2026-11-22",
                              location: Coordinate(latitude: 43, longitude: -81), placeName: "Hall",
                              collectedAt: Date(timeIntervalSince1970: 1_795_000_000),
                              imageURL: URL(string: "https://example.com/s.png"),
                              localImageURL: URL(fileURLWithPath: "/tmp/stickers/a.png"))
        let data = try JSONCoding.encoder.encode([sticker])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"local_image_url\""))
        #expect(json.contains("\"quest_id\""))
        let decoded = try JSONCoding.decoder.decode([Sticker].self, from: data)
        #expect(decoded.first?.questID == sticker.questID)
        #expect(decoded.first?.imageURL == sticker.imageURL)
        #expect(decoded.first?.localImageURL == sticker.localImageURL)
    }

    @MainActor @Test func profileReloadsLocalStickersFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stickers = dir.appendingPathComponent("stickers", isDirectory: true)
        try FileManager.default.createDirectory(at: stickers, withIntermediateDirectories: true)
        let png = stickers.appendingPathComponent("a.png")
        try Data([1, 2, 3]).write(to: png)

        let store = JSONFileStore<[Sticker]>(filename: "local-stickers.json", directory: dir)
        let history = ExpeditionHistory(store: nil)
        let first = ProfileModel(api: MockFogAPI(), history: history, localStickerStore: store)
        first.addLocalSticker(Sticker(questID: UUID(), category: "tree", questDate: "2026-11-22",
                                      location: Coordinate(latitude: 43, longitude: -81),
                                      collectedAt: .now, localImageURL: png))

        let relaunched = ProfileModel(api: MockFogAPI(), history: history, localStickerStore: store)
        #expect(relaunched.stickers.count == 1)
        #expect(relaunched.stickers.first?.localImageURL?.lastPathComponent == "a.png")
    }
}

@Suite @MainActor struct LocalFeedTests {
    @Test func localPostsMergeNewestFirstAndSurviveRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<[FeedPost]>(filename: "local-feed.json", directory: dir)
        let feed = FeedModel(api: MockFogAPI(latency: .zero), pageSize: 4, localStore: store)
        await feed.refresh()
        let start = Coordinate(latitude: 43.0096, longitude: -81.2737)
        let post = FeedPost.local(
            id: UUID(), author: .init(id: UUID(), name: "You", isMe: true),
            startedAt: .now.addingTimeInterval(-60), endedAt: .now.addingTimeInterval(3600),
            distanceM: 500, newTiles: 3,
            segments: [[start, Geo.offset(start, north: 200, east: 0), Geo.offset(start, north: 200, east: 100)]],
            sticker: nil)
        feed.addLocalPost(post)
        #expect(feed.posts.first?.id == post.id)
        #expect(feed.posts.count == feed.serverPosts.count + 1)
        #expect(post.durationS == 3660)

        let shape = try #require(post.routeShape)
        #expect(shape.count == 3)
        #expect(shape.allSatisfy { (0 ... 1).contains($0.x) && (0 ... 1).contains($0.y) })
        #expect(shape[0].y > shape[1].y) // north is up

        let relaunched = FeedModel(api: MockFogAPI(latency: .zero), localStore: store)
        #expect(relaunched.localPosts.map(\.id) == [post.id])

        // A sticker saved under an old app container path is found again in the current folder.
        let stickers = dir.appendingPathComponent("stickers", isDirectory: true)
        try FileManager.default.createDirectory(at: stickers, withIntermediateDirectories: true)
        try Data([1]).write(to: stickers.appendingPathComponent("s.png"))
        var moved = post
        moved.sticker = .init(url: URL(fileURLWithPath: "/old/container/stickers/s.png"), category: "tree", placeName: nil)
        feed.addLocalPost(moved)
        let again = FeedModel(api: MockFogAPI(latency: .zero), localStore: store)
        #expect(again.localPosts.first?.sticker?.url == stickers.appendingPathComponent("s.png"))
    }
}
