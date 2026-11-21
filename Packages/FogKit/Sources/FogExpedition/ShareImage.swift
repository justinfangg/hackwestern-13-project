import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO

/// Renders any SwiftUI view (Jonathan's recap card) to a PNG for sharing (PRD E-3).
///
/// Usage in a view:
/// ```swift
/// if let image = ShareImage.render(ExpeditionCardView(summary: s), size: ShareImage.storySize) {
///     ShareLink(item: image, preview: SharePreview("My expedition", image: image.preview))
/// }
/// ```
public enum ShareImage {
    /// 9:16 Instagram-story size in points (PRD E-5); rendered at 3x = 1080×1920 px.
    public static let storySize = CGSize(width: 360, height: 640)

    @MainActor
    public static func render<V: View>(_ view: V, size: CGSize = storySize, scale: CGFloat = 3) -> SharePNG? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let cg = renderer.cgImage, let data = pngData(cg) else { return nil }
        return SharePNG(data: data, cgImage: cg)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// A rendered PNG that works with `ShareLink`.
public struct SharePNG: Transferable, @unchecked Sendable {
    public let data: Data
    public let cgImage: CGImage

    /// For `SharePreview` thumbnails.
    public var preview: Image { Image(decorative: cgImage, scale: 3) }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}
