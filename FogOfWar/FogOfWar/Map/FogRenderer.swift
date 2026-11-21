import CoreGraphics
import MapKit
import QuartzCore
import UIKit

/// Draws the entire fog system as one MapKit overlay. H3 work and coordinate
/// conversion happen before geometry reaches this type; draw calls only query a
/// spatial index and issue Core Graphics commands for the dirty map rectangle.
final class FogRenderer: MKOverlayRenderer {
    /// Supplied by `FogMapView.Coordinator` so drifting fog invalidates only the
    /// currently visible geography instead of the world overlay.
    @MainActor var visibleMapRectProvider: (() -> MKMapRect?)?

    @MainActor var atmosphericMotionEnabled = true {
        didSet {
            ensureDisplayLink()
            displayLink?.isPaused = !atmosphericMotionEnabled && !hasActiveAnimations
        }
    }

    private let appearance: FogAppearance
    private let stateLock = NSLock()
    private var clearedIndex = GeometrySpatialIndex()
    private var revealAnimations: [H3CellID: CellRevealAnimation] = [:]
    private var renderTime = CACurrentMediaTime()
    private var lastAtmosphericInvalidation = CACurrentMediaTime()

    private let primaryTexture: CGImage?
    private let secondaryTexture: CGImage?
    private let clearingGradient: CGGradient?
    private let revealBloomGradient: CGGradient?

    private lazy var displayLinkProxy = FogDisplayLinkProxy(renderer: self)
    private var displayLink: CADisplayLink?

    private var hasActiveAnimations: Bool {
        stateLock.fogWithLock {
            !revealAnimations.isEmpty
        }
    }

    init(overlay: MKOverlay, appearance: FogAppearance = .default) {
        self.appearance = appearance
        primaryTexture = Self.makeAtmosphereTexture(
            size: 256,
            tint: (red: 116, green: 135, blue: 146),
            seed: 0.73
        )
        secondaryTexture = Self.makeAtmosphereTexture(
            size: 256,
            tint: (red: 151, green: 163, blue: 168),
            seed: 2.19
        )
        clearingGradient = Self.makeGradient(
            colors: [
                UIColor(white: 1, alpha: 1),
                UIColor(white: 1, alpha: 1),
                UIColor(white: 1, alpha: 0.72),
                UIColor(white: 1, alpha: 0)
            ],
            locations: [0, 0.68, 0.82, 1]
        )
        revealBloomGradient = Self.makeGradient(
            colors: [
                appearance.tealGlowColor.withAlphaComponent(0.20),
                appearance.tealGlowColor.withAlphaComponent(0.10),
                appearance.tealGlowColor.withAlphaComponent(0)
            ],
            locations: [0, 0.46, 1]
        )
        super.init(overlay: overlay)
    }

    deinit {
        displayLink?.invalidate()
    }

    /// Replaces the complete persisted cleared-cell snapshot without animating
    /// it. This is the startup/restore path and intentionally invalidates once.
    @MainActor
    func setClearedGeometries(_ geometries: [CellGeometry]) {
        let dirtyRect = stateLock.fogWithLock { () -> MKMapRect in
            let oldRect = clearedIndex.coveringMapRect
            clearedIndex.replace(with: geometries)
            revealAnimations.removeAll(keepingCapacity: true)
            return union(oldRect, clearedIndex.coveringMapRect)
        }

        ensureDisplayLink()
        invalidate(dirtyRect)
    }

    /// Incrementally adds newly cleared cells and schedules their presentation
    /// animation. All cells are in the spatial index immediately, so persistence
    /// and visual animation never disagree after an interruption.
    @MainActor
    func reveal(
        _ geometries: [CellGeometry],
        origin: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        style: FogRevealStyle
    ) {
        guard !geometries.isEmpty else { return }

        let now = CACurrentMediaTime()
        let originMapPoint = MKMapPoint(origin)
        let safeRadius = max(radiusMeters, 1)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        let dirtyRect = stateLock.fogWithLock { () -> MKMapRect in
            var dirty = MKMapRect.null

            for geometry in geometries {
                clearedIndex.upsert(geometry)

                let distance = originMapPoint.distance(to: geometry.centerMapPoint)
                let normalizedDistance = min(max(distance / safeRadius, 0), 1)

                let delay = reduceMotion ? 0 : normalizedDistance * appearance.normalMaximumStagger
                let duration = reduceMotion ? 0.16 : appearance.normalRevealDuration

                revealAnimations[geometry.id] = CellRevealAnimation(
                    startTime: now,
                    delay: delay,
                    duration: duration,
                    style: style,
                    dirtyMapRect: expandedMapRect(for: geometry)
                )
                dirty = union(dirty, expandedMapRect(for: geometry))
            }

            renderTime = now
            return dirty
        }

        ensureDisplayLink()
        displayLink?.isPaused = false
        invalidate(dirtyRect)
    }

    /// Clears exploration render state while retaining the cached visible grid,
    /// so a reset returns to a fully fogged map with its hex territory texture.
    @MainActor
    func reset() {
        let dirtyRect = stateLock.fogWithLock { () -> MKMapRect in
            let oldRect = clearedIndex.coveringMapRect
            clearedIndex.removeAll()
            revealAnimations.removeAll(keepingCapacity: true)
            return oldRect
        }

        ensureDisplayLink()
        invalidate(dirtyRect)
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        true
    }

    override func draw(
        _ mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        in context: CGContext
    ) {
        let drawRect = rect(for: mapRect)
        guard !drawRect.isEmpty else { return }

        let paddedQueryRect = mapRectPaddedForSoftClearing(mapRect)
        let snapshot = stateLock.fogWithLock {
            FogRenderSnapshot(
                cleared: clearedIndex.geometries(intersecting: paddedQueryRect),
                animations: revealAnimations,
                time: renderTime
            )
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Copying the base alpha avoids accumulating opacity when MapKit redraws
        // the same backing tile multiple times.
        context.setBlendMode(.copy)
        context.setFillColor(appearance.baseFogColor.cgColor)
        context.fill(drawRect)
        context.restoreGState()

        drawAtmosphere(in: drawRect, at: snapshot.time, context: context)
        punchClearedCells(
            snapshot.cleared,
            animations: snapshot.animations,
            time: snapshot.time,
            context: context
        )
        drawRevealGlows(
            snapshot.cleared,
            animations: snapshot.animations,
            time: snapshot.time,
            context: context
        )
    }

    // MARK: - Core Graphics drawing

    private func drawAtmosphere(
        in drawRect: CGRect,
        at time: CFTimeInterval,
        context: CGContext
    ) {
        guard !drawRect.isEmpty else { return }

        if let primaryTexture {
            let phase = CGPoint(
                x: CGFloat(time) * appearance.primaryDriftVelocity.x,
                y: CGFloat(time) * appearance.primaryDriftVelocity.y
            )
            drawTiledTexture(
                primaryTexture,
                in: drawRect,
                tileSize: appearance.primaryTextureTileSize,
                phase: phase,
                opacity: appearance.primaryTextureOpacity,
                blendMode: .normal,
                context: context
            )
        }

        if let secondaryTexture {
            let phase = CGPoint(
                x: CGFloat(time) * appearance.secondaryDriftVelocity.x,
                y: CGFloat(time) * appearance.secondaryDriftVelocity.y
            )
            drawTiledTexture(
                secondaryTexture,
                in: drawRect,
                tileSize: appearance.secondaryTextureTileSize,
                phase: phase,
                opacity: appearance.secondaryTextureOpacity,
                blendMode: .screen,
                context: context
            )
        }
    }

    private func drawTiledTexture(
        _ image: CGImage,
        in drawRect: CGRect,
        tileSize: CGFloat,
        phase: CGPoint,
        opacity: CGFloat,
        blendMode: CGBlendMode,
        context: CGContext
    ) {
        guard tileSize > 0 else { return }

        let wrappedX = phase.x.truncatingRemainder(dividingBy: tileSize)
        let wrappedY = phase.y.truncatingRemainder(dividingBy: tileSize)
        var x = floor((drawRect.minX - wrappedX) / tileSize) * tileSize + wrappedX
        let startY = floor((drawRect.minY - wrappedY) / tileSize) * tileSize + wrappedY

        context.saveGState()
        context.clip(to: drawRect)
        context.setAlpha(opacity)
        context.setBlendMode(blendMode)

        while x < drawRect.maxX {
            var y = startY
            while y < drawRect.maxY {
                context.draw(
                    image,
                    in: CGRect(x: x, y: y, width: tileSize, height: tileSize)
                )
                y += tileSize
            }
            x += tileSize
        }

        context.restoreGState()
    }

    private func punchClearedCells(
        _ geometries: [CellGeometry],
        animations: [H3CellID: CellRevealAnimation],
        time: CFTimeInterval,
        context: CGContext
    ) {
        guard let clearingGradient, !geometries.isEmpty else { return }

        context.saveGState()
        context.setBlendMode(.destinationOut)

        for geometry in geometries {
            guard projectedEdgeLength(of: geometry) >= appearance.minimumClearEdgeLength else {
                continue
            }

            let progress = animations[geometry.id].map {
                revealProgress(for: $0, at: time)
            } ?? 1
            guard progress > 0 else { continue }

            let center = point(for: geometry.centerMapPoint)
            let settledRadius = projectedRadius(of: geometry) * appearance.clearMaskRadiusScale
            let dispersalScale = 0.74 + 0.26 * progress

            context.saveGState()
            context.setAlpha(progress)
            context.drawRadialGradient(
                clearingGradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: settledRadius * dispersalScale,
                options: []
            )
            context.restoreGState()
        }

        context.restoreGState()
    }

    private func drawRevealGlows(
        _ geometries: [CellGeometry],
        animations: [H3CellID: CellRevealAnimation],
        time: CFTimeInterval,
        context: CGContext
    ) {
        guard let revealBloomGradient else { return }

        context.saveGState()
        context.setBlendMode(.screen)

        for geometry in geometries {
            guard let animation = animations[geometry.id] else {
                continue
            }

            let opacity = glowOpacity(for: animation, at: time)
            guard opacity > 0 else { continue }

            let center = point(for: geometry.centerMapPoint)
            let radius = projectedRadius(of: geometry) * appearance.revealBloomRadiusScale
            context.saveGState()
            context.setAlpha(opacity)
            context.drawRadialGradient(
                revealBloomGradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: radius,
                options: []
            )
            context.restoreGState()
        }

        context.restoreGState()
    }

    private func projectedEdgeLength(of geometry: CellGeometry) -> CGFloat {
        guard geometry.boundary.count >= 2 else { return 0 }
        let start = point(for: geometry.boundary[0])
        let end = point(for: geometry.boundary[1])
        return hypot(end.x - start.x, end.y - start.y)
    }

    private func projectedRadius(of geometry: CellGeometry) -> CGFloat {
        let center = point(for: geometry.centerMapPoint)
        return geometry.boundary.reduce(CGFloat.zero) { radius, mapPoint in
            let vertex = point(for: mapPoint)
            return max(radius, hypot(vertex.x - center.x, vertex.y - center.y))
        }
    }

    // MARK: - Animation scheduling

    @MainActor
    private func ensureDisplayLink() {
        if displayLink == nil {
            let link = CADisplayLink(
                target: displayLinkProxy,
                selector: #selector(FogDisplayLinkProxy.displayLinkDidFire(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 15,
                maximum: 60,
                preferred: 30
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @MainActor
    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        let now = link.timestamp
        let animationUpdate = stateLock.fogWithLock { () -> AnimationUpdate in
            renderTime = now
            var dirty = MKMapRect.null

            revealAnimations = revealAnimations.filter { _, animation in
                dirty = union(dirty, animation.dirtyMapRect)
                return now < animation.endTime
            }

            return AnimationUpdate(
                dirtyMapRect: dirty,
                hasActiveAnimations: !revealAnimations.isEmpty
            )
        }

        var dirtyRect = animationUpdate.dirtyMapRect
        if atmosphericMotionEnabled,
           now - lastAtmosphericInvalidation >= 1 / appearance.atmosphericFramesPerSecond,
           let visibleRect = visibleMapRectProvider?()
        {
            lastAtmosphericInvalidation = now
            dirtyRect = union(dirtyRect, visibleRect)
        }

        if !dirtyRect.isNull, !dirtyRect.isEmpty {
            setNeedsDisplay(dirtyRect)
        }

        link.isPaused = !atmosphericMotionEnabled && !animationUpdate.hasActiveAnimations
    }

    @MainActor
    private func invalidate(_ mapRect: MKMapRect) {
        if !mapRect.isNull, !mapRect.isEmpty {
            setNeedsDisplay(mapRect)
        } else if let visibleRect = visibleMapRectProvider?() {
            setNeedsDisplay(visibleRect)
        } else {
            setNeedsDisplay()
        }
    }

    private func revealProgress(
        for animation: CellRevealAnimation,
        at time: CFTimeInterval
    ) -> CGFloat {
        let phase = normalizedProgress(
            now: time,
            start: animation.startTime + animation.delay,
            duration: animation.duration
        )
        let fadePhase = min(max((phase - 0.14) / 0.62, 0), 1)
        return CGFloat(smoothStep(fadePhase))
    }

    private func glowOpacity(
        for animation: CellRevealAnimation,
        at time: CFTimeInterval
    ) -> CGFloat {
        let phase = normalizedProgress(
            now: time,
            start: animation.startTime + animation.delay,
            duration: animation.duration
        )
        guard phase > 0, phase < 1 else { return 0 }

        if phase < 0.18 {
            return CGFloat(smoothStep(phase / 0.18))
        }
        return CGFloat(1 - smoothStep((phase - 0.18) / 0.82))
    }

    private func normalizedProgress(
        now: CFTimeInterval,
        start: CFTimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((now - start) / duration, 0), 1)
    }

    private func smoothStep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func expandedMapRect(for geometry: CellGeometry) -> MKMapRect {
        let padding = max(geometry.mapRect.size.width, geometry.mapRect.size.height) * 0.55
        return geometry.mapRect.insetBy(dx: -padding, dy: -padding)
    }

    private func mapRectPaddedForSoftClearing(_ mapRect: MKMapRect) -> MKMapRect {
        let latitude = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate.latitude
        let padding = 80 * MKMapPointsPerMeterAtLatitude(latitude)
        return mapRect.insetBy(dx: -padding, dy: -padding)
    }

    private func union(_ lhs: MKMapRect, _ rhs: MKMapRect) -> MKMapRect {
        if lhs.isNull { return rhs }
        if rhs.isNull { return lhs }
        return lhs.union(rhs)
    }

    // MARK: - Procedural texture

    private static func makeGradient(colors: [UIColor], locations: [CGFloat]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: locations
        )
    }

    /// Produces a seamless periodic cloud texture once. Integer-frequency waves
    /// keep every tile edge continuous while layered billows avoid a flat wash.
    private static func makeAtmosphereTexture(
        size: Int,
        tint: (red: UInt8, green: UInt8, blue: UInt8),
        seed: Double
    ) -> CGImage? {
        guard size > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let twoPi = Double.pi * 2

        for y in 0 ..< size {
            for x in 0 ..< size {
                let u = Double(x) / Double(size)
                let v = Double(y) / Double(size)
                let broad = sin(twoPi * u + seed) * cos(twoPi * v - seed * 0.61)
                let cross = sin(twoPi * (2 * u + v) + seed * 0.43)
                    * cos(twoPi * (u - 2 * v) - seed)
                let middle = sin(twoPi * (3 * u - 2 * v) + seed * 1.17)
                    * cos(twoPi * (2 * u + 3 * v) + seed * 0.56)
                let fine = sin(twoPi * (6 * u - 4 * v) + seed * 1.47)
                    * cos(twoPi * (5 * u + 7 * v) - seed * 0.62)
                let billow = abs(sin(twoPi * (2 * u - v) + seed * 0.29)) * 2 - 1
                let wave = broad * 0.42
                    + cross * 0.27
                    + middle * 0.17
                    + fine * 0.07
                    + billow * 0.07
                let normalized = min(max((wave + 1) * 0.5, 0), 1)
                let shaped = normalized * normalized * (3 - 2 * normalized)
                let alpha = UInt8(8 + shaped * 70)
                let offset = (y * size + x) * 4

                // premultipliedLast requires channels to be premultiplied.
                bytes[offset] = UInt8(UInt16(tint.red) * UInt16(alpha) / 255)
                bytes[offset + 1] = UInt8(UInt16(tint.green) * UInt16(alpha) / 255)
                bytes[offset + 2] = UInt8(UInt16(tint.blue) * UInt16(alpha) / 255)
                bytes[offset + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }

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

// MARK: - Render state

private struct FogRenderSnapshot {
    let cleared: [CellGeometry]
    let animations: [H3CellID: CellRevealAnimation]
    let time: CFTimeInterval
}

private struct CellRevealAnimation {
    let startTime: CFTimeInterval
    let delay: TimeInterval
    let duration: TimeInterval
    let style: FogRevealStyle
    let dirtyMapRect: MKMapRect

    var endTime: CFTimeInterval {
        startTime + delay + duration
    }
}

private struct AnimationUpdate {
    let dirtyMapRect: MKMapRect
    let hasActiveAnimations: Bool
}

/// A fixed Web-Mercator bucket index. Cells are indexed into every bucket their
/// map rect intersects, so dirty-rect queries cannot miss a cell centered just
/// beyond a bucket boundary.
private struct GeometrySpatialIndex {
    private static let bucketSide: Double = 4_096

    private struct BucketKey: Hashable {
        let x: Int
        let y: Int
    }

    private var geometriesByID: [H3CellID: CellGeometry] = [:]
    private var bucketIDs: [BucketKey: Set<H3CellID>] = [:]
    private(set) var coveringMapRect = MKMapRect.null

    mutating func replace(with geometries: [CellGeometry]) {
        geometriesByID.removeAll(keepingCapacity: true)
        bucketIDs.removeAll(keepingCapacity: true)
        coveringMapRect = .null
        for geometry in geometries {
            upsert(geometry)
        }
    }

    mutating func upsert(_ geometry: CellGeometry) {
        if let previous = geometriesByID[geometry.id] {
            removeFromBuckets(previous)
        }

        geometriesByID[geometry.id] = geometry
        for key in bucketKeys(intersecting: geometry.mapRect) {
            bucketIDs[key, default: []].insert(geometry.id)
        }
        coveringMapRect = mapRectUnion(coveringMapRect, geometry.mapRect)
    }

    mutating func removeAll() {
        geometriesByID.removeAll(keepingCapacity: true)
        bucketIDs.removeAll(keepingCapacity: true)
        coveringMapRect = .null
    }

    func geometries(intersecting mapRect: MKMapRect) -> [CellGeometry] {
        guard !mapRect.isNull, !mapRect.isEmpty else {
            return []
        }

        var candidateIDs = Set<H3CellID>()
        for key in queryBucketKeys(intersecting: mapRect) {
            if let ids = bucketIDs[key] {
                candidateIDs.formUnion(ids)
            }
        }

        return candidateIDs.compactMap { id in
            guard let geometry = geometriesByID[id],
                  geometry.mapRect.intersects(mapRect)
            else {
                return nil
            }
            return geometry
        }
    }

    private mutating func removeFromBuckets(_ geometry: CellGeometry) {
        for key in bucketKeys(intersecting: geometry.mapRect) {
            bucketIDs[key]?.remove(geometry.id)
            if bucketIDs[key]?.isEmpty == true {
                bucketIDs.removeValue(forKey: key)
            }
        }
    }

    private func bucketKeys(intersecting mapRect: MKMapRect) -> [BucketKey] {
        guard !mapRect.isNull, !mapRect.isEmpty else {
            return []
        }

        let minimumX = Int(floor(mapRect.origin.x / Self.bucketSide))
        let minimumY = Int(floor(mapRect.origin.y / Self.bucketSide))
        let maximumX = Int(floor((mapRect.origin.x + mapRect.size.width) / Self.bucketSide))
        let maximumY = Int(floor((mapRect.origin.y + mapRect.size.height) / Self.bucketSide))

        var keys: [BucketKey] = []
        keys.reserveCapacity((maximumX - minimumX + 1) * (maximumY - minimumY + 1))
        for y in minimumY ... maximumY {
            for x in minimumX ... maximumX {
                keys.append(BucketKey(x: x, y: y))
            }
        }
        return keys
    }

    /// At street zoom, calculating the handful of keys covered by a dirty rect
    /// is fastest. At country/world zoom, that key range can contain millions of
    /// empty buckets; scanning only the buckets that actually hold exploration
    /// data keeps the query bounded by the sparse data set instead.
    private func queryBucketKeys(intersecting mapRect: MKMapRect) -> [BucketKey] {
        guard !mapRect.isNull, !mapRect.isEmpty, !bucketIDs.isEmpty else {
            return []
        }

        let minimumX = Int(floor(mapRect.origin.x / Self.bucketSide))
        let minimumY = Int(floor(mapRect.origin.y / Self.bucketSide))
        let maximumX = Int(floor((mapRect.origin.x + mapRect.size.width) / Self.bucketSide))
        let maximumY = Int(floor((mapRect.origin.y + mapRect.size.height) / Self.bucketSide))
        let columnCount = maximumX - minimumX + 1
        let rowCount = maximumY - minimumY + 1
        let directLookupLimit = max(bucketIDs.count * 4, 128)
        let directLookupIsBounded = rowCount > 0
            && columnCount > 0
            && columnCount <= directLookupLimit / rowCount

        if directLookupIsBounded {
            return bucketKeys(intersecting: mapRect)
        }

        return bucketIDs.keys.filter { key in
            let bucketRect = MKMapRect(
                x: Double(key.x) * Self.bucketSide,
                y: Double(key.y) * Self.bucketSide,
                width: Self.bucketSide,
                height: Self.bucketSide
            )
            return bucketRect.intersects(mapRect)
        }
    }

    private func mapRectUnion(_ lhs: MKMapRect, _ rhs: MKMapRect) -> MKMapRect {
        if lhs.isNull { return rhs }
        if rhs.isNull { return lhs }
        return lhs.union(rhs)
    }
}

private final class FogDisplayLinkProxy: NSObject {
    weak var renderer: FogRenderer?

    init(renderer: FogRenderer) {
        self.renderer = renderer
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        MainActor.assumeIsolated {
            renderer?.displayLinkDidFire(displayLink)
        }
    }
}

private extension NSLock {
    @inline(__always)
    func fogWithLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try operation()
    }
}
