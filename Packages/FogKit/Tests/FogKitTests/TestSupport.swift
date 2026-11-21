import Foundation
import CoreGraphics
@testable import FogKit

/// Fixed clock that tests advance manually.
final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_795_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    var closure: () -> Date { { self.now } }
}

func fix(_ c: Coordinate, at t: Date, accuracy: Double = 5) -> LocationFix {
    LocationFix(coordinate: c, timestamp: t, horizontalAccuracy: accuracy, speed: nil, source: .gps)
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FogKitTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func solidImage(width: Int = 64, height: Int = 48) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

struct PassthroughExtractor: StickerExtracting {
    func extractSticker(from image: CGImage) async -> CGImage { image }
}

final class StubVerifier: QuestVerifying, @unchecked Sendable {
    var results: [Result<VerificationResult, Error>]
    private(set) var requests: [VerifyQuestRequest] = []
    var calls: Int { requests.count }
    init(_ results: [Result<VerificationResult, Error>]) { self.results = results }
    func verify(_ request: VerifyQuestRequest, quest: Quest, image: CGImage) async throws -> VerificationResult {
        requests.append(request)
        return try results.removeFirst().get()
    }
}

final class StubAuth: AuthTokenProviding, @unchecked Sendable {
    private(set) var refreshes = 0
    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes += 1 }
        return "test-token-\(refreshes)"
    }
}

/// Path to the API contract's example responses (repo root docs/mocks).
func mockURL(_ name: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/mocks/\(name)")
}

func mockData(_ name: String) throws -> Data { try Data(contentsOf: mockURL(name)) }
