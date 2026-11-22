import CoreGraphics
import MapKit
import QuartzCore
import UIKit

/// Draws the cloud cover as one MapKit overlay. H3 work and coordinate
/// conversion happen before geometry reaches this type; draw calls only query a
/// spatial index and issue Core Graphics commands for the dirty map rectangle.
///
/// Layers per tile: a grey haze, procedural fog banks of varying density
/// (skipping any bank whose center sits on explored ground), then a soft
/// punch-out of every cleared H3 cell so walked paths are always readable.
final class FogRenderer: MKOverlayRenderer {
    /// Supplied by `FogMapView.Coordinator`; used when a dirty rect is unknown.
    @MainActor var visibleMapRectProvider: (() -> MKMapRect?)?

    private let appearance: FogAppearance
    private let atlas = CloudSpriteAtlas.shared
    private let stateLock = NSLock()
    private var clearedIndex = GeometrySpatialIndex()
    private var revealAnimations: [H3CellID: CellRevealAnimation] = [:]
    private var renderTime = CACurrentMediaTime()
    private var lastDrawnCloudLevel = 0

    private let clearingGradient: CGGradient?
    /// Soft circular mask for settled (fully revealed) cells. Drawn via `CGContext.draw`
    /// instead of `drawRadialGradient`, which is cheaper when many cells are punched.
    private let settledClearMask: CGImage?

    private lazy var displayLinkProxy = FogDisplayLinkProxy(renderer: self)
    private var displayLink: CADisplayLink?

    init(overlay: MKOverlay, appearance: FogAppearance = .default) {
        self.appearance = appearance
        clearingGradient = Self.makeGradient(
            colors: [
                UIColor(white: 1, alpha: 1),
                UIColor(white: 1, alpha: 1),
                UIColor(white: 1, alpha: 0.72),
                UIColor(white: 1, alpha: 0)
            ],
            locations: [0, 0.6, 0.8, 1]
        )
        settledClearMask = Self.makeSettledClearMask(size: 128)
        super.init(overlay: overlay)
    }

    deinit {
        displayLink?.invalidate()
    }

    /// Cloud level-of-detail most recently drawn; dispersal animations use the
    /// same level so the clouds that fly away are the ones that were on screen.
    var currentCloudLevel: Int {
        stateLock.fogWithLock { lastDrawnCloudLevel }
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
        invalidate(expandedForClouds(dirtyRect, level: currentCloudLevel))
    }

    /// Incrementally adds newly cleared cells and schedules their presentation
    /// animation. Returns the clouds that were visible before this reveal and
    /// are now on explored ground, so the caller can fade them out in place.
    @MainActor
    @discardableResult
    func reveal(
        _ geometries: [CellGeometry],
        origin: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        style: FogRevealStyle
    ) -> [CloudSprite] {
        guard !geometries.isEmpty else { return [] }

        let now = CACurrentMediaTime()
        let originMapPoint = MKMapPoint(origin)
        let safeRadius = max(radiusMeters, 1)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let level = currentCloudLevel
        let clearRadius = CloudField.clearRadius(level: level)

        var revealRect = MKMapRect.null
        for geometry in geometries {
            revealRect = union(revealRect, geometry.mapRect)
        }
        let candidateClouds = CloudField.clouds(
            withCentersIn: revealRect.insetBy(dx: -clearRadius, dy: -clearRadius),
            level: level
        )

        let (dirtyRect, dispersed) = stateLock.fogWithLock { () -> (MKMapRect, [CloudSprite]) in
            let visibleBefore = candidateClouds.filter { !isCloudCleared($0, level: level) }
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

            let dispersed = visibleBefore.filter { isCloudCleared($0, level: level) }
            for cloud in dispersed {
                let extent = cloud.drawSize
                dirty = union(dirty, MKMapRect(
                    x: cloud.centerX - extent.width,
                    y: cloud.centerY - extent.height,
                    width: extent.width * 2,
                    height: extent.height * 2
                ))
            }

            renderTime = now
            return (dirty, dispersed)
        }

        ensureDisplayLink()
        invalidate(dirtyRect)
        return dispersed
    }

    /// Clears exploration render state so the map returns to full cloud cover.
    @MainActor
    func reset() {
        let dirtyRect = stateLock.fogWithLock { () -> MKMapRect in
            let oldRect = clearedIndex.coveringMapRect
            clearedIndex.removeAll()
            revealAnimations.removeAll(keepingCapacity: true)
            return oldRect
        }
        invalidate(expandedForClouds(dirtyRect, level: currentCloudLevel))
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

        let level = CloudField.level(forZoomScale: Double(zoomScale))
        let clouds = CloudField.clouds(intersecting: mapRect, level: level)
        let cloudProbePadding = CloudField.maximumDrawExtent(level: level)
            + CloudField.clearRadius(level: level)
        let queryRect = mapRect
            .insetBy(dx: -cloudProbePadding, dy: -cloudProbePadding)
            .union(mapRectPaddedForSoftClearing(mapRect))

        let snapshot = stateLock.fogWithLock { () -> FogRenderSnapshot in
            lastDrawnCloudLevel = level
            return FogRenderSnapshot(
                cleared: clearedIndex.geometries(intersecting: queryRect),
                animations: revealAnimations,
                time: renderTime
            )
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .medium

        // Copying the base alpha avoids accumulating opacity when MapKit redraws
        // the same backing tile multiple times.
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(appearance.baseFogColor.cgColor)
        context.fill(drawRect)
        context.restoreGState()

        drawClouds(clouds, cleared: snapshot.cleared, level: level, clip: drawRect, context: context)
        punchClearedCells(
            snapshot.cleared,
            animations: snapshot.animations,
            time: snapshot.time,
            context: context
        )
        context.restoreGState()
    }

    // MARK: - Core Graphics drawing

    private func drawClouds(
        _ clouds: [CloudSprite],
        cleared: [CellGeometry],
        level: Int,
        clip: CGRect,
        context: CGContext
    ) {
        guard !clouds.isEmpty else { return }
        let clearCircles = Self.clearCircles(for: cleared, clearRadius: CloudField.clearRadius(level: level))

        context.saveGState()
        context.clip(to: clip)
        // Fog textures are soft and low-resolution; bilinear is plenty.
        context.interpolationQuality = .low
        for cloud in clouds {
            guard let image = atlas.image(at: cloud.spriteIndex, tone: cloud.tone),
                  !Self.isCloudCleared(cloud, among: clearCircles)
            else { continue }

            let size = cloud.drawSize
            let center = point(for: cloud.center)
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: cloud.rotation)
            // The overlay context is y-down; CGImages draw y-up.
            context.scaleBy(x: cloud.isFlipped ? -1 : 1, y: -1)
            context.setAlpha(cloud.opacity)
            context.draw(
                image,
                in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            )
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func punchClearedCells(
        _ geometries: [CellGeometry],
        animations: [H3CellID: CellRevealAnimation],
        time: CFTimeInterval,
        context: CGContext
    ) {
        guard !geometries.isEmpty else { return }

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
            let dispersalScale = 0.7 + 0.3 * progress
            let radius = settledRadius * dispersalScale

            context.saveGState()
            context.setAlpha(progress)
            if progress >= 0.999, let settledClearMask {
                let diameter = radius * 2
                context.draw(
                    settledClearMask,
                    in: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: diameter,
                        height: diameter
                    )
                )
            } else if let clearingGradient {
                context.drawRadialGradient(
                    clearingGradient,
                    startCenter: center,
                    startRadius: 0,
                    endCenter: center,
                    endRadius: radius,
                    options: []
                )
            }
            context.restoreGState()
        }

        context.restoreGState()
    }

    // MARK: - Cloud clearing

    /// Must be called with `stateLock` held.
    private func isCloudCleared(_ cloud: CloudSprite, level: Int) -> Bool {
        let clearRadius = CloudField.clearRadius(level: level)
        let probe = clearRadius + 1_200
        let nearby = clearedIndex.geometries(intersecting: MKMapRect(
            x: cloud.centerX - probe,
            y: cloud.centerY - probe,
            width: probe * 2,
            height: probe * 2
        ))
        return Self.isCloudCleared(cloud, among: Self.clearCircles(for: nearby, clearRadius: clearRadius))
    }

    struct ClearCircle {
        let x: Double
        let y: Double
        let radiusSquared: Double
    }

    /// Flattens cleared cells into plain circles once per draw so the
    /// per-cloud test is a tight loop over doubles.
    static func clearCircles(for geometries: [CellGeometry], clearRadius: Double) -> [ClearCircle] {
        geometries.map { geometry in
            let cellRadius = max(geometry.mapRect.size.width, geometry.mapRect.size.height) * 0.5
            let radius = max(clearRadius, cellRadius)
            return ClearCircle(
                x: geometry.centerMapPoint.x,
                y: geometry.centerMapPoint.y,
                radiusSquared: radius * radius
            )
        }
    }

    /// A fog bank fades out once any explored cell is within the clear
    /// radius of its center (or the center sits inside that cell).
    static func isCloudCleared(_ cloud: CloudSprite, among circles: [ClearCircle]) -> Bool {
        for circle in circles {
            let dx = circle.x - cloud.centerX
            let dy = circle.y - cloud.centerY
            if dx * dx + dy * dy < circle.radiusSquared {
                return true
            }
        }
        return false
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
        let update = stateLock.fogWithLock { () -> AnimationUpdate in
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

        if !update.dirtyMapRect.isNull, !update.dirtyMapRect.isEmpty {
            setNeedsDisplay(update.dirtyMapRect)
        }
        link.isPaused = !update.hasActiveAnimations
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

    private func expandedForClouds(_ mapRect: MKMapRect, level: Int) -> MKMapRect {
        guard !mapRect.isNull else { return mapRect }
        let padding = CloudField.maximumDrawExtent(level: level) + CloudField.clearRadius(level: level)
        return mapRect.insetBy(dx: -padding, dy: -padding)
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
        let fadePhase = min(max((phase - 0.08) / 0.75, 0), 1)
        return CGFloat(smoothStep(fadePhase))
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

    // MARK: - Masks

    private static func makeGradient(colors: [UIColor], locations: [CGFloat]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: locations
        )
    }

    /// Rasterises the settled clear falloff once. Matches the live clearing
    /// gradient's opaque core + soft rim so the swap is visually invisible.
    private static func makeSettledClearMask(size: Int) -> CGImage? {
        guard size > 0,
              let context = CGContext(
                  data: nil,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let gradient = makeGradient(
                  colors: [
                      UIColor(white: 1, alpha: 1),
                      UIColor(white: 1, alpha: 1),
                      UIColor(white: 1, alpha: 0.72),
                      UIColor(white: 1, alpha: 0)
                  ],
                  locations: [0, 0.6, 0.8, 1]
              )
        else {
            return nil
        }

        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: CGFloat(size) / 2,
            options: []
        )
        return context.makeImage()
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
