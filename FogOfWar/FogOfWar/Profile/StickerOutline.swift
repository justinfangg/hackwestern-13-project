import CoreImage
import UIKit

/// Native rendering of Figma's "Cutout outline" effect (outside placement,
/// no softness): the sticker's opaque pixels are dilated by `thickness` with a
/// circular kernel, filled white, and drawn underneath the artwork.
///
/// Rendered once per sticker and cached, so dragging stickers around costs no
/// per-frame image work.
nonisolated enum StickerOutline {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let cache = NSCache<NSString, UIImage>()

    /// - Parameters:
    ///   - image: Sticker artwork with a transparent background.
    ///   - canvas: The sticker's frame in points.
    ///   - imageRect: Where the artwork sits inside `canvas`, in points.
    ///   - thickness: Outline width in points.
    /// - Returns: The outlined sticker, `padding(for:)` larger than `canvas` on every side.
    static func render(
        _ image: UIImage,
        cacheKey: String,
        canvas: CGSize,
        imageRect: CGRect,
        thickness: CGFloat,
        scale: CGFloat
    ) -> UIImage? {
        let key = "\(cacheKey)-\(canvas.width)x\(canvas.height)-\(thickness)@\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let pad = padding(for: thickness)
        let size = CGSize(width: canvas.width + pad * 2, height: canvas.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let artwork = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: imageRect.offsetBy(dx: pad, dy: pad))
        }
        guard let cgArtwork = artwork.cgImage else { return nil }

        let input = CIImage(cgImage: cgArtwork)
        let extent = input.extent
        let silhouette = CIImage(color: .white)
            .cropped(to: extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: input])
        let outline = silhouette
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: thickness * scale])
            .cropped(to: extent)
        let composed = input.composited(over: outline)

        guard let cgResult = context.createCGImage(composed, from: extent) else { return nil }
        let result = UIImage(cgImage: cgResult, scale: scale, orientation: .up)
        cache.setObject(result, forKey: key)
        return result
    }

    /// Room left around the canvas so the outline isn't clipped.
    static func padding(for thickness: CGFloat) -> CGFloat {
        ceil(thickness) + 2
    }
}
