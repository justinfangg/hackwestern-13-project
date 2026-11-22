import MapKit
import QuartzCore
import UIKit

/// Short-lived layer that fades out fog the player has just walked into.
///
/// When exploration clears ground under a fog bank, the tile renderer stops
/// drawing it and hands the bank to this view, which keeps it exactly where it
/// was and dissolves it. Positions are tracked in map space every frame so the
/// fading fog stays glued to the map while the player pans or zooms.
final class CloudDispersalView: UIView {
    weak var mapView: MKMapView?

    private struct Puff {
        let cloud: CloudSprite
        let layer: CALayer
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
    }

    private let appearance: FogAppearance
    private let atlas = CloudSpriteAtlas.shared
    private var puffs: [Puff] = []
    private var displayLink: CADisplayLink?

    init(appearance: FogAppearance = .default) {
        self.appearance = appearance
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    /// `origin` only staggers the fade slightly so fog nearest the player
    /// dissolves first; nothing moves.
    func disperse(_ clouds: [CloudSprite], awayFrom origin: CLLocationCoordinate2D) {
        guard !clouds.isEmpty else { return }
        let originPoint = MKMapPoint(origin)
        let now = CACurrentMediaTime()
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        for cloud in clouds where !puffs.contains(where: { $0.cloud == cloud }) {
            guard let image = atlas.image(at: cloud.spriteIndex, tone: cloud.tone) else { continue }
            var random = SplitMix64(seed: UInt64(bitPattern: Int64(cloud.key.hashValue)))

            let distance = hypot(cloud.centerX - originPoint.x, cloud.centerY - originPoint.y)
            let normalized = min(distance / max(cloud.width, 1), 1)
            let delay = reduceMotion ? 0 : normalized * appearance.dispersalMaximumStagger
            let duration = reduceMotion
                ? 0.25
                : appearance.dispersalFadeDuration * (0.85 + random.nextUnit() * 0.3)

            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "transform": NSNull()]
            self.layer.addSublayer(layer)

            puffs.append(Puff(cloud: cloud, layer: layer, startTime: now + delay, duration: duration))
        }

        updatePuffs(at: now)
        startDisplayLinkIfNeeded()
    }

    func removeAllPuffs() {
        puffs.forEach { $0.layer.removeFromSuperlayer() }
        puffs.removeAll()
        displayLink?.isPaused = true
    }

    private func startDisplayLinkIfNeeded() {
        if displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget(owner: self), selector: #selector(DisplayLinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        updatePuffs(at: link.targetTimestamp)
        if puffs.isEmpty {
            link.isPaused = true
        }
    }

    private func updatePuffs(at time: CFTimeInterval) {
        guard let mapView, bounds.width > 0 else { return }
        let visible = mapView.visibleMapRect
        guard visible.size.width > 0 else { return }
        let scale = Double(bounds.width) / visible.size.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        puffs.removeAll { puff in
            let phase = min(max((time - puff.startTime) / puff.duration, 0), 1)
            guard phase < 1 else {
                puff.layer.removeFromSuperlayer()
                return true
            }

            // Ease-in-out so the fog thins gently, then vanishes.
            let fade = 1 - phase * phase * (3 - 2 * phase)
            let size = puff.cloud.drawSize

            puff.layer.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            puff.layer.position = CGPoint(
                x: (puff.cloud.centerX - visible.minX) * scale,
                y: (puff.cloud.centerY - visible.minY) * scale
            )
            puff.layer.opacity = Float(puff.cloud.opacity * CGFloat(fade))

            var transform = CATransform3DMakeRotation(puff.cloud.rotation, 0, 0, 1)
            transform = CATransform3DScale(transform, puff.cloud.isFlipped ? -1 : 1, 1, 1)
            puff.layer.transform = transform
            return false
        }

        CATransaction.commit()
    }
}

/// Breaks the CADisplayLink → target retain cycle.
private final class DisplayLinkTarget: NSObject {
    weak var owner: CloudDispersalView?

    init(owner: CloudDispersalView) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        MainActor.assumeIsolated {
            owner.tick(link)
        }
    }
}
