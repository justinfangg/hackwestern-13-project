import MapKit
import QuartzCore
import UIKit

/// Short-lived layer that plays the "pushing the clouds aside" effect.
///
/// When exploration clears ground under a cloud, the tile renderer stops
/// drawing it and hands the cloud to this view, which slides it away from the
/// player with a critically damped spring, swells it slightly, then lets it
/// fade out. Positions are tracked in map space every frame so the puffs stay
/// glued to the map while the player pans or zooms mid-animation.
final class CloudDispersalView: UIView {
    weak var mapView: MKMapView?

    private struct Puff {
        let cloud: CloudSprite
        let layer: CALayer
        let directionX: Double
        let directionY: Double
        let distance: Double
        let swirl: CGFloat
        let startTime: CFTimeInterval
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

    func disperse(_ clouds: [CloudSprite], awayFrom origin: CLLocationCoordinate2D) {
        guard !clouds.isEmpty else { return }
        let originPoint = MKMapPoint(origin)
        let now = CACurrentMediaTime()
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        for cloud in clouds where !puffs.contains(where: { $0.cloud == cloud }) {
            guard let image = atlas.image(at: cloud.spriteIndex) else { continue }
            var random = SplitMix64(seed: UInt64(bitPattern: Int64(cloud.key.hashValue)))

            var dx = cloud.centerX - originPoint.x
            var dy = cloud.centerY - originPoint.y
            var length = hypot(dx, dy)
            if length < 1 {
                let angle = random.nextUnit() * .pi * 2
                dx = cos(angle)
                dy = sin(angle)
                length = 1
            }
            // Fan the push out a little so neighbouring clouds don't move in lockstep.
            let wobble = (random.nextUnit() - 0.5) * 0.6
            let baseAngle = atan2(dy / length, dx / length) + wobble

            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "transform": NSNull()]
            self.layer.addSublayer(layer)

            puffs.append(Puff(
                cloud: cloud,
                layer: layer,
                directionX: cos(baseAngle),
                directionY: sin(baseAngle),
                distance: reduceMotion ? 0 : cloud.width * (0.75 + random.nextUnit() * 0.35),
                swirl: CGFloat((random.nextUnit() - 0.5) * 0.25),
                startTime: now
            ))
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
        let totalDuration = appearance.dispersalFadeDelay + appearance.dispersalFadeDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        puffs.removeAll { puff in
            let elapsed = max(time - puff.startTime, 0)
            guard elapsed < totalDuration else {
                puff.layer.removeFromSuperlayer()
                return true
            }

            // Critically damped spring: fast initial shove that eases to rest.
            let omega = 5.2 / appearance.dispersalPushDuration
            let push = 1 - (1 + omega * elapsed) * exp(-omega * elapsed)
            let fadePhase = min(max((elapsed - appearance.dispersalFadeDelay) / appearance.dispersalFadeDuration, 0), 1)
            let fade = 1 - fadePhase * fadePhase * (3 - 2 * fadePhase)

            let worldX = puff.cloud.centerX + puff.directionX * puff.distance * push
            let worldY = puff.cloud.centerY + puff.directionY * puff.distance * push
            let size = puff.cloud.drawSize
            let swell = 1 + 0.14 * push

            puff.layer.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            puff.layer.position = CGPoint(x: (worldX - visible.minX) * scale, y: (worldY - visible.minY) * scale)
            puff.layer.opacity = Float(puff.cloud.opacity * CGFloat(fade))

            var transform = CATransform3DMakeRotation(puff.cloud.rotation + puff.swirl * CGFloat(push), 0, 0, 1)
            transform = CATransform3DScale(transform, (puff.cloud.isFlipped ? -1 : 1) * swell, swell, 1)
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
