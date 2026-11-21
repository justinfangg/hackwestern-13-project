import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// CGImage helpers that work on iOS and macOS (no UIKit).
public enum ImageEncoding {
    /// Downscales so the longest side is at most `maxDimension`, then JPEG-encodes (PRD §10.5: ≤ 1024 px).
    public static func jpeg(_ image: CGImage, maxDimension: Int = 1024, quality: Double = 0.8) -> Data? {
        encode(downscaled(image, maxDimension: maxDimension), type: .jpeg,
               options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    public static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, options: [:])
    }

    /// Decodes image file data (e.g. a camera capture), applying EXIF orientation so the result is upright.
    public static func uprightImage(from data: Data, maxDimension: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
