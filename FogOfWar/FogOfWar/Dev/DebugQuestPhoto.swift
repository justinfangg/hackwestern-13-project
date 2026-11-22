#if DEBUG
import UIKit

/// Debug quest-camera bypass (Debug menu → "Bypass camera & Gemini"): the stand-in for a photo.
/// A random pre-cut sticker (transparent PNG of an object) from the asset catalog, so the whole
/// quest flow can be tested without a camera, a location, or a verifier.
enum DebugQuestPhoto {
    private static let assetNames = ["StickerBench", "StickerTree", "StickerLampWreath", "StickerMapleLeaf"]

    static func random() -> CGImage? {
        UIImage(named: assetNames.randomElement() ?? "StickerBench")?.cgImage
    }
}
#endif
