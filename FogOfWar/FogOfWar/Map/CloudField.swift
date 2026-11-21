import CoreImage
import MapKit
import UIKit

/// One cloud puff placed in world (Web Mercator) space. Positions and styling
/// are derived from a hash of the grid slot, so every map tile, every redraw
/// and the dispersal animation agree on exactly the same cloud.
nonisolated struct CloudSprite: Hashable, Sendable {
    struct Key: Hashable, Sendable {
        let level: Int
        let column: Int
        let row: Int
        let slot: Int
    }

    let key: Key
    let centerX: Double
    let centerY: Double
    /// Width / height of the cloud shape (not counting blur padding), in map points.
    let width: Double
    let height: Double
    let spriteIndex: Int
    let opacity: CGFloat
    let isFlipped: Bool
    let rotation: CGFloat

    var center: MKMapPoint { MKMapPoint(x: centerX, y: centerY) }

    /// Drawn footprint including the blur halo baked into the sprite image.
    var drawSize: (width: Double, height: Double) {
        let pad = width * Double(CloudSpriteAtlas.paddingFraction) * 2
        return (width + pad, height + pad)
    }

    static func == (lhs: CloudSprite, rhs: CloudSprite) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Deterministic, level-of-detail cloud layout.
///
/// Level 0 is street zoom (the Figma frame: ~90 pt between crowns). Each level
/// up doubles spacing and cloud size so the number of puffs per screen stays
/// roughly constant as the player zooms out.
nonisolated enum CloudField {
    static let baseSpacingX: Double = 900
    static let baseSpacingY: Double = 640
    static let maximumLevel = 16
    /// Coarsen once level-0 clouds would sit closer than this on screen.
    private static let minimumScreenSpacing: Double = 54

    static func level(forZoomScale zoomScale: Double) -> Int {
        guard zoomScale.isFinite, zoomScale > 0 else { return maximumLevel }
        let screenSpacing = baseSpacingX * zoomScale
        if screenSpacing >= minimumScreenSpacing { return 0 }
        let level = Int(ceil(log2(minimumScreenSpacing / screenSpacing)))
        return min(max(level, 0), maximumLevel)
    }

    static func spacing(level: Int) -> (x: Double, y: Double) {
        let factor = Double(1 << level)
        return (baseSpacingX * factor, baseSpacingY * factor)
    }

    /// A cloud is "pushed away" once explored ground lies this close to its center.
    static func clearRadius(level: Int) -> Double {
        spacing(level: level).x * 0.55
    }

    /// Largest distance from a cloud center to the edge of its drawn sprite.
    static func maximumDrawExtent(level: Int) -> Double {
        let spacing = spacing(level: level)
        let width = spacing.x * 1.75
        let padded = width * (1 + 2 * Double(CloudSpriteAtlas.paddingFraction))
        return padded * 0.75 + spacing.x * 0.35
    }

    /// Every cloud whose drawn sprite might touch `mapRect`.
    static func clouds(intersecting mapRect: MKMapRect, level: Int) -> [CloudSprite] {
        clouds(withCentersIn: mapRect.insetBy(
            dx: -maximumDrawExtent(level: level),
            dy: -maximumDrawExtent(level: level)
        ), level: level)
    }

    /// Every cloud whose center lies inside `mapRect`.
    static func clouds(withCentersIn mapRect: MKMapRect, level: Int) -> [CloudSprite] {
        guard !mapRect.isNull, !mapRect.isEmpty else { return [] }
        let spacing = spacing(level: level)
        let jitterMargin = spacing.x
        let minRow = Int(floor((mapRect.minY - jitterMargin) / spacing.y))
        let maxRow = Int(ceil((mapRect.maxY + jitterMargin) / spacing.y))
        let minColumn = Int(floor((mapRect.minX - jitterMargin) / spacing.x)) - 1
        let maxColumn = Int(ceil((mapRect.maxX + jitterMargin) / spacing.x))

        // Guard against pathological rects (e.g. a world-sized dirty rect).
        guard (maxRow - minRow) * (maxColumn - minColumn) < 20_000 else { return [] }

        var result: [CloudSprite] = []
        for row in minRow ... maxRow {
            for column in minColumn ... maxColumn {
                for slot in 0 ..< 2 {
                    guard let cloud = cloud(level: level, column: column, row: row, slot: slot),
                          mapRect.contains(cloud.center)
                    else { continue }
                    result.append(cloud)
                }
            }
        }
        return result
    }

    private static func cloud(level: Int, column: Int, row: Int, slot: Int) -> CloudSprite? {
        var random = SplitMix64(seed: seed(level: level, column: column, row: row, slot: slot))
        let spacing = spacing(level: level)

        // Slot 1 is an occasional smaller puff: slight density variation.
        if slot == 1, random.nextUnit() > 0.3 { return nil }

        let stagger = row.isMultiple(of: 2) ? 0 : 0.5
        var x = (Double(column) + stagger) * spacing.x
        var y = Double(row) * spacing.y
        x += (random.nextUnit() - 0.5) * spacing.x * 0.5
        y += (random.nextUnit() - 0.5) * spacing.y * 0.45

        let widthScale = slot == 0
            ? 1.32 + random.nextUnit() * 0.36
            : 0.85 + random.nextUnit() * 0.3
        if slot == 1 {
            x += (random.nextUnit() - 0.5) * spacing.x * 0.9
            y += (random.nextUnit() - 0.5) * spacing.y * 0.9
        }

        let spriteIndex = Int(random.next() % UInt64(CloudSpriteAtlas.names.count))
        let width = spacing.x * widthScale
        let height = width * CloudSpriteAtlas.aspectRatios[spriteIndex] * (0.92 + random.nextUnit() * 0.16)
        let opacity = CGFloat(0.8 + random.nextUnit() * 0.17)
        let flipped = random.nextUnit() < 0.5
        let rotation = CGFloat((random.nextUnit() - 0.5) * 0.22)

        return CloudSprite(
            key: .init(level: level, column: column, row: row, slot: slot),
            centerX: x,
            centerY: y,
            width: width,
            height: height,
            spriteIndex: spriteIndex,
            opacity: opacity,
            isFlipped: flipped,
            rotation: rotation
        )
    }

    private static func seed(level: Int, column: Int, row: Int, slot: Int) -> UInt64 {
        var hash: UInt64 = 0x9E37_79B9_7F4A_7C15
        for value in [level, column, row, slot] {
            hash ^= UInt64(bitPattern: Int64(value)) &+ 0x9E37_79B9_7F4A_7C15 &+ (hash << 6) &+ (hash >> 2)
        }
        return hash
    }
}

nonisolated struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// The Figma "Cloud crown" vectors, rasterised once with the layer blur the
/// design applies. Shared by the tile renderer and the dispersal animation.
nonisolated final class CloudSpriteAtlas: @unchecked Sendable {
    static let shared = CloudSpriteAtlas()

    static let names = [
        "CloudCrown07", "CloudCrown08", "CloudCrown09", "CloudCrown10",
        "CloudCrown11", "CloudCrown12", "CloudCrown13", "CloudCrown14"
    ]

    /// Height / width of each crown's Figma frame.
    static let aspectRatios: [Double] = [
        104.818 / 119.385, 107.177 / 109.572, 112.542 / 137.166, 112.426 / 140.584,
        110.217 / 127.465, 93.6022 / 121.844, 93.5105 / 139.482, 95.6573 / 119.779
    ]

    /// Transparent margin (fraction of the shape width) on every side that
    /// leaves room for the blur to fall off.
    static let paddingFraction: CGFloat = 0.3
    /// Gaussian sigma as a fraction of the shape width (Figma layer blur).
    private static let blurFraction: CGFloat = 0.075
    private static let shapePixelWidth: CGFloat = 220

    let images: [CGImage?]

    private init() {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        images = Self.names.indices.map { index in
            Self.renderSprite(named: Self.names[index], aspect: Self.aspectRatios[index], context: context)
        }
    }

    func image(at index: Int) -> CGImage? {
        guard images.indices.contains(index) else { return nil }
        return images[index]
    }

    private static func renderSprite(named name: String, aspect: Double, context: CIContext) -> CGImage? {
        guard let vector = UIImage(named: name) else { return nil }

        let shapeWidth = shapePixelWidth
        let shapeHeight = (shapeWidth * aspect).rounded()
        let pad = (shapeWidth * paddingFraction).rounded()
        let canvas = CGSize(width: shapeWidth + pad * 2, height: shapeHeight + pad * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let flat = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            vector.draw(in: CGRect(x: pad, y: pad, width: shapeWidth, height: shapeHeight))
        }
        guard let flatCG = flat.cgImage else { return nil }

        let input = CIImage(cgImage: flatCG)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return flatCG }
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(shapeWidth * blurFraction, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: input.extent) else { return flatCG }
        return context.createCGImage(output, from: input.extent) ?? flatCG
    }
}
