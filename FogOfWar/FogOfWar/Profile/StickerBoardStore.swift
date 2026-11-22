import CoreGraphics
import Foundation
import Observation

/// A sticker on the profile's memory board.
///
/// Geometry is in the board's design space (Figma "Memory Board", 336 × 526 pt
/// inside its 5 pt border); the board scales it to the size it's given.
struct BoardSticker: Identifiable, Sendable {
    struct Shadow: Sendable {
        var opacity: Double
        /// SwiftUI radius (half of Figma's blur).
        var radius: CGFloat
        var y: CGFloat
    }

    let id: String
    let imageName: String
    /// The sticker's frame (Figma "Memory Image").
    let size: CGSize
    /// Where the artwork sits in `size`, as fractions of it.
    let imageRect: CGRect
    let rotation: Double
    /// Figma "Cutout outline" thickness.
    let outline: CGFloat
    let shadow: Shadow?
    /// Center on the board before the player moves it.
    let defaultCenter: CGPoint

    var accessibilityName: String
}

extension BoardSticker {
    static let designBoardSize = CGSize(width: 336, height: 526)

    /// Placeholder stickers from the Figma frame. Real ones will come from quest
    /// photos (the camera lifts the subject into a sticker, see `StickerExtractor`).
    static let demo: [BoardSticker] = [
        BoardSticker(
            id: "demo.maple-leaf",
            imageName: "StickerMapleLeaf",
            size: CGSize(width: 241.582, height: 162.008),
            imageRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            rotation: 13.09,
            outline: 8.587,
            shadow: Shadow(opacity: 0.33, radius: 20.9, y: 0),
            defaultCenter: CGPoint(x: 64, y: 161.26),
            accessibilityName: "Maple leaf"
        ),
        BoardSticker(
            id: "demo.bench",
            imageName: "StickerBench",
            size: CGSize(width: 190.958, height: 190.958),
            imageRect: CGRect(x: 0.0549, y: 0.0533, width: 0.8911, height: 0.8911),
            rotation: -70.58,
            outline: 10.882,
            shadow: Shadow(opacity: 0.27, radius: 15.45, y: 5.616),
            defaultCenter: CGPoint(x: 245.79, y: 120.79),
            accessibilityName: "Park bench"
        ),
        BoardSticker(
            id: "demo.tree",
            imageName: "StickerTree",
            size: CGSize(width: 237.662, height: 178.246),
            imageRect: CGRect(x: 0.0462, y: -0.0005, width: 0.9089, height: 0.908),
            rotation: 25.19,
            outline: 14.546,
            shadow: nil,
            defaultCenter: CGPoint(x: 80.46, y: 350.23),
            accessibilityName: "Tree"
        ),
        BoardSticker(
            id: "demo.lamp-wreath",
            imageName: "StickerLampWreath",
            size: CGSize(width: 152.362, height: 200.848),
            imageRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            rotation: 70.06,
            outline: 5.915,
            shadow: nil,
            defaultCenter: CGPoint(x: 247.39, y: 464.86),
            accessibilityName: "Street lamp with a wreath"
        ),
    ]
}

/// Where each sticker sits on the board and which is on top, saved across launches.
@MainActor
@Observable
final class StickerBoardStore {
    struct Placement: Codable, Equatable {
        /// Center as a fraction of the board's width and height.
        var x: Double
        var y: Double
        /// Stacking order; higher draws on top.
        var z: Int
    }

    static let shared = StickerBoardStore()

    private(set) var placements: [String: Placement]

    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "profile.stickerBoard.placements.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Placement].self, from: data) {
            placements = saved
        } else {
            placements = [:]
        }
    }

    func placement(for sticker: BoardSticker, order: Int) -> Placement {
        placements[sticker.id] ?? Placement(
            x: sticker.defaultCenter.x / BoardSticker.designBoardSize.width,
            y: sticker.defaultCenter.y / BoardSticker.designBoardSize.height,
            z: order
        )
    }

    /// Puts a sticker above every other one on the board.
    func bringToFront(_ sticker: BoardSticker, among stickers: [BoardSticker]) {
        materialize(stickers)
        let others = stickers.filter { $0.id != sticker.id }.compactMap { placements[$0.id]?.z }
        let top = others.max() ?? 0
        guard let z = placements[sticker.id]?.z, z <= top else { return }
        placements[sticker.id]?.z = top + 1
        save()
    }

    /// Moves a sticker; `center` is a fraction of the board's width and height.
    func move(_ sticker: BoardSticker, to center: CGPoint, among stickers: [BoardSticker]) {
        materialize(stickers)
        placements[sticker.id]?.x = center.x
        placements[sticker.id]?.y = center.y
        save()
    }

    /// Stores every sticker's current (possibly default) placement so the
    /// stacking order stays stable once the player starts rearranging.
    private func materialize(_ stickers: [BoardSticker]) {
        for (index, sticker) in stickers.enumerated() where placements[sticker.id] == nil {
            placements[sticker.id] = placement(for: sticker, order: index)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(placements) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
