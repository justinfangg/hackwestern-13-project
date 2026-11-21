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
    @Test func usesSnakeCaseAndISODates() throws {
        let req = VerifyQuestRequest(questId: UUID(), photoBase64: "abc", location: .westernCampus,
                                     capturedAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try JSONCoding.encoder.encode(req), as: UTF8.self)
        #expect(json.contains("\"quest_id\""))
        #expect(json.contains("\"photo_base64\""))
        #expect(json.contains("\"captured_at\":\"1970-01-01T00:00:00Z\""))
    }

    @Test func decodesFractionalSecondDates() throws {
        let json = #"{"verified":true,"confidence":0.9,"reason":"ok","attempts_remaining":4}"#
        let r = try JSONCoding.decoder.decode(VerificationResult.self, from: Data(json.utf8))
        #expect(r.attemptsRemaining == 4)
        struct D: Decodable { var at: Date }
        let d = try JSONCoding.decoder.decode(D.self, from: Data(#"{"at":"2026-11-21T12:00:00.123Z"}"#.utf8))
        #expect(d.at.timeIntervalSince1970 > 0)
    }
}
