#if DEBUG
import Foundation
import FogKit

/// Launch-only sample data for visually checking both sticker-detail states.
///
/// These fixtures never enter production data stores or networking. Launch the
/// debug app with exactly one of:
/// - `-holographic-expedition-fixture`
/// - `-holographic-sticker-only-fixture`
struct HolographicStickerDebugFixture {
    enum Kind {
        case expedition
        case stickerOnly
    }

    let kind: Kind

    static var current: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-holographic-expedition-fixture") {
            return Self(kind: .expedition)
        }
        if arguments.contains("-holographic-sticker-only-fixture") {
            return Self(kind: .stickerOnly)
        }
        return nil
    }

    var boardSticker: BoardSticker { BoardSticker.demo[0] }

    var collectedSticker: Sticker {
        Sticker(
            id: UUID(uuidString: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAAA")!,
            questID: UUID(uuidString: "BBBBBBBB-2222-4222-8222-BBBBBBBBBBBB")!,
            category: "nature",
            questDate: "2026-11-21",
            location: .westernCampus,
            placeName: "Sample river trail",
            collectedAt: sampleStart.addingTimeInterval(5_400)
        )
    }

    var expedition: ExpeditionSummary? {
        guard kind == .expedition else { return nil }
        let route = Self.sampleRoute
        return ExpeditionSummary(
            id: UUID(uuidString: "CCCCCCCC-3333-4333-8333-CCCCCCCCCCCC")!,
            startedAt: sampleStart,
            endedAt: sampleStart.addingTimeInterval(6_720),
            distanceMeters: 12_180,
            newTiles: 84,
            segments: [route],
            sticker: collectedSticker
        )
    }

    private var sampleStart: Date {
        Date(timeIntervalSince1970: 1_795_250_400)
    }

    private static var sampleRoute: [Coordinate] {
        let start = Coordinate.westernCampus
        return (0...42).map { index in
            let progress = Double(index)
            return Geo.offset(
                start,
                north: progress * 28,
                east: sin(progress / 4.8) * 145 + progress * 7
            )
        }
    }
}
#endif
