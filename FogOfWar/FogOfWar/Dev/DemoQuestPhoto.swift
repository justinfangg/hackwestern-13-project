#if DEBUG
import UIKit
import FogKit

/// Demo mode (Debug menu → "Demo mode"): the sample photo the quest camera shows and captures, and its
/// subject cut out ahead of time. Apple's subject lifting needs the Neural Engine, which the iOS
/// Simulator doesn't have, so the cut-out was made on a Mac with the same Vision request
/// (`VNGenerateForegroundInstanceMaskRequest`) and bundled as `DemoQuestPhotoCutout`.
enum DemoQuestPhoto {
    static let image: CGImage? = UIImage(named: "DemoQuestPhoto")?.cgImage

    /// The flowers alone, at the photo's full size (transparent elsewhere), for the peel-off animation.
    static let cutout: SubjectCutout? = {
        guard let image = UIImage(named: "DemoQuestPhotoCutout")?.cgImage,
              let bounds = VisionStickerExtractor.opaqueBounds(of: image) else { return nil }
        return SubjectCutout(image: image, bounds: bounds)
    }()

    /// The flowers cropped to their bounds: the sticker that's saved.
    static let sticker: CGImage? = {
        guard let cutout else { return nil }
        let w = CGFloat(cutout.image.width), h = CGFloat(cutout.image.height)
        let crop = CGRect(x: cutout.bounds.minX * w, y: cutout.bounds.minY * h,
                          width: cutout.bounds.width * w, height: cutout.bounds.height * h).integral
        return cutout.image.cropping(to: crop)
    }()
}
#endif
