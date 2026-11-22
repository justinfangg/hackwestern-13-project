import Accelerate
import MapKit
import UIKit

/// One fog bank placed in world (Web Mercator) space. Positions and styling
/// are derived from a hash of the grid slot, so every map tile, every redraw
/// and the dispersal animation agree on exactly the same patch of fog.
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
    /// Drawn width / height of the fog texture, in map points. The texture's
    /// soft falloff reaches zero before its edges, so no extra padding applies.
    let width: Double
    let height: Double
    let spriteIndex: Int
    /// Grey shade, 0 (darkest) ..< `CloudSpriteAtlas.toneCount` (lightest). Neighbouring
    /// banks share a shade, so the fog reads as lighter and darker layers.
    let tone: Int
    let opacity: CGFloat
    let isFlipped: Bool
    let rotation: CGFloat

    var center: MKMapPoint { MKMapPoint(x: centerX, y: centerY) }

    var drawSize: (width: Double, height: Double) { (width, height) }

    static func == (lhs: CloudSprite, rhs: CloudSprite) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Deterministic, level-of-detail fog layout.
///
/// Level 0 is street zoom. Each level up doubles spacing and bank size so the
/// number of fog banks per screen stays roughly constant as the player zooms
/// out. A low-frequency density field makes some regions thick and others
/// barely-there wisps.
nonisolated enum CloudField {
    static let baseSpacingX: Double = 1_300
    static let baseSpacingY: Double = 900
    static let maximumLevel = 16
    /// Coarsen once level-0 banks would sit closer than this on screen.
    private static let minimumScreenSpacing: Double = 78

    /// Largest bank width as a multiple of `spacing.x` (see `cloud(level:...)`).
    private static let maximumWidthScale: Double = 2.8
    private static let maximumHeightRatio: Double = 0.74

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

    /// A fog bank fades out once explored ground lies this close to its center.
    /// Kept small relative to the (large) banks so walking past the edge of a
    /// bank only dissolves the patch you walked through.
    static func clearRadius(level: Int) -> Double {
        spacing(level: level).x * 0.4
    }

    /// Largest distance from a bank center to the edge of its drawn texture.
    static func maximumDrawExtent(level: Int) -> Double {
        let halfWidth = spacing(level: level).x * maximumWidthScale * 0.5
        return hypot(halfWidth, halfWidth * maximumHeightRatio)
    }

    /// Every bank whose drawn texture might touch `mapRect`.
    static func clouds(intersecting mapRect: MKMapRect, level: Int) -> [CloudSprite] {
        clouds(withCentersIn: mapRect.insetBy(
            dx: -maximumDrawExtent(level: level),
            dy: -maximumDrawExtent(level: level)
        ), level: level)
    }

    /// Every bank whose center lies inside `mapRect`.
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
        result.reserveCapacity((maxRow - minRow + 1) * (maxColumn - minColumn + 1) * 2)
        for row in minRow ... maxRow {
            for column in minColumn ... maxColumn {
                let density = density(level: level, column: column, row: row)
                for slot in 0 ..< 3 {
                    guard let cloud = cloud(level: level, column: column, row: row, slot: slot, density: density),
                          mapRect.contains(cloud.center)
                    else { continue }
                    result.append(cloud)
                }
            }
        }
        return result
    }

    /// Smooth 0...1 fog thickness for a grid slot. Pushed towards the extremes
    /// so the map has clearly thin patches and clearly dense ones.
    private static func density(level: Int, column: Int, row: Int) -> Double {
        let seed = UInt64(truncatingIfNeeded: level &* 7_919 &+ 104_729)
        let raw = FogNoise.fbm(
            x: Double(column) * 0.31,
            y: Double(row) * 0.42,
            seed: seed,
            octaves: 3
        )
        return FogNoise.smoothStep(0.28, 0.72, raw)
    }

    /// Shade of the fog around a bank center: a slow noise field over a few banks, so whole patches
    /// come out lighter or darker. Most of the map stays at the middle shades.
    private static func tone(level: Int, x: Double, y: Double, slot: Int) -> Int {
        let spacing = spacing(level: level)
        let raw = FogNoise.fbm(
            x: x / (spacing.x * 4.5),
            y: y / (spacing.y * 4.5),
            seed: UInt64(truncatingIfNeeded: level &* 31_337 &+ 2_718_281),
            octaves: 2
        )
        let shade = FogNoise.smoothStep(0.25, 0.75, raw)
        var tone = Int((shade * Double(CloudSpriteAtlas.toneCount)).rounded(.down))
        // Wisps drift in front of the banks: one step lighter reads as a separate layer.
        if slot == 1 { tone += 1 }
        return min(max(tone, 0), CloudSpriteAtlas.toneCount - 1)
    }

    private static func cloud(level: Int, column: Int, row: Int, slot: Int, density: Double) -> CloudSprite? {
        var random = SplitMix64(seed: seed(level: level, column: column, row: row, slot: slot))
        let spacing = spacing(level: level)

        let stagger = row.isMultiple(of: 2) ? 0 : 0.5
        var x = (Double(column) + stagger) * spacing.x
        var y = Double(row) * spacing.y
        x += (random.nextUnit() - 0.5) * spacing.x * 0.5
        y += (random.nextUnit() - 0.5) * spacing.y * 0.45

        let widthScale: Double
        let heightRatio: Double
        var opacity = 0.5 + 0.45 * density

        switch slot {
        case 0:
            // Main bank. Thin regions drop some banks entirely so only the
            // base haze and stray wisps remain there.
            if density < 0.2, random.nextUnit() > 0.6 + density * 2 { return nil }
            widthScale = 1.7 + random.nextUnit() * (maximumWidthScale - 1.7)
            heightRatio = 0.42 + random.nextUnit() * (maximumHeightRatio - 0.42)
            opacity *= 0.85 + random.nextUnit() * 0.15
        case 1:
            // Long, faint wisp drifting between banks.
            if random.nextUnit() > 0.3 + density * 0.5 { return nil }
            x += (random.nextUnit() - 0.5) * spacing.x * 1.2
            y += (random.nextUnit() - 0.5) * spacing.y * 1.0
            widthScale = 1.2 + random.nextUnit() * 0.9
            heightRatio = 0.32 + random.nextUnit() * 0.22
            opacity *= 0.7 + random.nextUnit() * 0.2
        default:
            // Small dense knot that only forms where fog is already thick.
            if random.nextUnit() > density * 0.65 { return nil }
            x += (random.nextUnit() - 0.5) * spacing.x * 0.8
            y += (random.nextUnit() - 0.5) * spacing.y * 0.8
            widthScale = 0.9 + random.nextUnit() * 0.5
            heightRatio = 0.5 + random.nextUnit() * 0.22
            opacity *= 0.85 + random.nextUnit() * 0.15
        }

        let width = spacing.x * widthScale
        return CloudSprite(
            key: .init(level: level, column: column, row: row, slot: slot),
            centerX: x,
            centerY: y,
            width: width,
            height: width * heightRatio,
            spriteIndex: Int(random.next() % UInt64(CloudSpriteAtlas.spriteCount)),
            tone: tone(level: level, x: x, y: y, slot: slot),
            opacity: CGFloat(min(max(opacity, 0.1), 0.95)),
            isFlipped: random.nextUnit() < 0.5,
            rotation: CGFloat((random.nextUnit() - 0.5) * 0.5)
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

/// Hash-based value noise; deterministic and allocation-free.
nonisolated enum FogNoise {
    static func smoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func lattice(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
        var h = seed ^ (UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15)
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h = (h ^ (h >> 31)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 29)) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 32
        return Double(h >> 11) / Double(1 << 53)
    }

    /// Smoothly interpolated value noise in [0, 1).
    static func value(x: Double, y: Double, seed: UInt64) -> Double {
        let x0 = floor(x), y0 = floor(y)
        let ix = Int(x0), iy = Int(y0)
        let fx = x - x0, fy = y - y0
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let a = lattice(ix, iy, seed)
        let b = lattice(ix + 1, iy, seed)
        let c = lattice(ix, iy + 1, seed)
        let d = lattice(ix + 1, iy + 1, seed)
        let top = a + (b - a) * sx
        let bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    /// Fractal sum of value noise, normalised to [0, 1).
    static func fbm(x: Double, y: Double, seed: UInt64, octaves: Int) -> Double {
        var sum = 0.0, amplitude = 0.5, frequency = 1.0, norm = 0.0
        for octave in 0 ..< octaves {
            sum += amplitude * value(x: x * frequency, y: y * frequency, seed: seed &+ UInt64(octave) &* 0x632B_E59B)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2.03
        }
        return sum / norm
    }
}

/// Small, procedurally generated fog textures shared by the tile renderer and
/// the dispersal fade. Each one is a cluster of soft lobes eroded by fractal
/// noise, so edges break up into wisps instead of reading as cartoon clouds.
/// Generating them is a few milliseconds of arithmetic: no asset decoding,
/// SVG rasterisation or Core Image blur.
nonisolated final class CloudSpriteAtlas: @unchecked Sendable {
    static let shared = CloudSpriteAtlas()
    static let spriteCount = 10
    /// Each texture is rendered in this many greys, darkest first (see `tones`).
    static let toneCount = 4
    /// (light core, dark edge) grey per tone. Tone 1 is the original fog colour; the others are
    /// a touch darker or noticeably lighter so patches of fog read as separate layers.
    private static let tones: [(light: Double, dark: Double)] = [
        (0.81, 0.73),
        (0.85, 0.77),
        (0.90, 0.83),
        (0.95, 0.89),
    ]
    /// Fog is soft, so a low-resolution texture scaled up looks identical and
    /// is far cheaper to draw than the previous blurred vector sprites.
    private static let pixelSize = 96
    /// Softening applied to every texture once, when it's generated: the width in texture pixels
    /// of the tent (≈ Gaussian) blur. Odd. 96 px textures, so 13 blurs edges by about 7%.
    private static let blurKernel = 13

    let images: [CGImage?]

    private init() {
        images = (0 ..< Self.toneCount).flatMap { tone in
            (0 ..< Self.spriteCount).map { Self.renderSprite(index: $0, tone: Self.tones[tone]) }
        }
    }

    func image(at index: Int, tone: Int) -> CGImage? {
        let slot = tone * Self.spriteCount + index
        guard index >= 0, index < Self.spriteCount, images.indices.contains(slot) else { return nil }
        return images[slot]
    }

    /// Tent-blurs premultiplied RGBA pixels in place (edges extend, so nothing darkens at the border).
    private static func blur(_ pixels: inout [UInt8], size: Int) {
        let kernel = UInt32(blurKernel | 1)
        var output = [UInt8](repeating: 0, count: pixels.count)
        let ok = pixels.withUnsafeMutableBytes { src -> Bool in
            output.withUnsafeMutableBytes { dst -> Bool in
                var source = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(size),
                                           width: vImagePixelCount(size), rowBytes: size * 4)
                var destination = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(size),
                                                width: vImagePixelCount(size), rowBytes: size * 4)
                return vImageTentConvolve_ARGB8888(&source, &destination, nil, 0, 0, kernel, kernel, nil,
                                                   vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
            }
        }
        if ok { pixels = output }
    }

    private struct Lobe {
        let x: Double
        let y: Double
        let inverseRadiusSquared: Double
        let weight: Double
    }

    private static func renderSprite(index: Int, tone: (light: Double, dark: Double)) -> CGImage? {
        let size = pixelSize
        let seed = UInt64(index + 1) &* 0xD1B5_4A32_D192_ED03
        var random = SplitMix64(seed: seed)

        // Lobes spread along a horizontal band; the field stretches them
        // further when it sets each bank's width and height.
        // Many overlapping lobes make each texture read as one big bunch.
        let lobeCount = 8 + Int(random.next() % 6)
        var lobes: [Lobe] = []
        for _ in 0 ..< lobeCount {
            let radius = 0.1 + random.nextUnit() * 0.11
            lobes.append(Lobe(
                x: (random.nextUnit() - 0.5) * 0.58,
                y: (random.nextUnit() - 0.5) * 0.36,
                inverseRadiusSquared: 1 / (radius * radius),
                weight: 0.45 + random.nextUnit() * 0.55
            ))
        }
        let noiseScale = 1.8 + random.nextUnit() * 1.4
        let noiseOffsetX = random.nextUnit() * 100
        let noiseOffsetY = random.nextUnit() * 100
        let erosion = 0.3 + random.nextUnit() * 0.25

        // Slightly warm grey: lighter in thick cores, darker in thin edges.
        let light: (r: Double, g: Double, b: Double) = (tone.light, tone.light, tone.light - 0.01)
        let dark: (r: Double, g: Double, b: Double) = (tone.dark, tone.dark, tone.dark - 0.01)

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for py in 0 ..< size {
            let v = (Double(py) + 0.5) / Double(size) - 0.5
            for px in 0 ..< size {
                let u = (Double(px) + 0.5) / Double(size) - 0.5

                var body = 0.0
                for lobe in lobes {
                    let dx = u - lobe.x, dy = v - lobe.y
                    body += lobe.weight * exp(-(dx * dx + dy * dy) * lobe.inverseRadiusSquared)
                }

                let noise = FogNoise.fbm(
                    x: u * noiseScale + noiseOffsetX,
                    // Higher vertical frequency streaks the fog sideways.
                    y: v * noiseScale * 2.4 + noiseOffsetY,
                    seed: seed,
                    octaves: 3
                )
                var alpha = body * (1 - erosion + erosion * 2 * noise)
                alpha = FogNoise.smoothStep(0.04, 0.95, alpha)

                // Force a clean fade to zero before the texture edge.
                let radial = hypot(u, v) * 2
                alpha *= 1 - FogNoise.smoothStep(0.72, 0.98, radial)
                guard alpha > 0.002 else { continue }

                let shade = min(max(alpha * 0.7 - v * 0.3 + noise * 0.15, 0), 1)
                let r = dark.r + (light.r - dark.r) * shade
                let g = dark.g + (light.g - dark.g) * shade
                let b = dark.b + (light.b - dark.b) * shade

                let offset = (py * size + px) * 4
                pixels[offset] = UInt8(min(r * alpha * 255, 255))
                pixels[offset + 1] = UInt8(min(g * alpha * 255, 255))
                pixels[offset + 2] = UInt8(min(b * alpha * 255, 255))
                pixels[offset + 3] = UInt8(min(alpha * 255, 255))
            }
        }

        blur(&pixels, size: size)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
