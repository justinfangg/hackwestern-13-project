import MapKit
import UIKit

/// Softly blurs the map wherever it is still unexplored, so streets under the
/// fog read as hazy instead of crisp.
///
/// MapKit can't blur its own tiles, so this sits above the map as a masked
/// `UIVisualEffectView`. The mask is a low-resolution bitmap in map space
/// (opaque = fog, soft holes = explored cells) that is only re-rendered when
/// exploration changes or the camera leaves the rendered area; while panning
/// and zooming we just move/scale that bitmap, so the per-frame cost is one
/// layer frame update. Quest pins and MapKit's legal label are cut out in
/// screen space so they stay sharp.
final class FogBlurView: UIView {
    weak var mapView: MKMapView?
    /// Supplies explored cells; set by the map coordinator once the fog
    /// renderer exists.
    var clearedGeometriesProvider: ((MKMapRect) -> [CellGeometry])?

    /// 0...1 strength of the system blur. The system blur at full strength is
    /// far too heavy for "a bit hazy".
    private let intensity: CGFloat
    /// Mask bitmap pixels per screen point. The mask edges are soft anyway.
    private let maskResolution: CGFloat = 0.4
    private let clearRadiusScale: Double = 1.6

    private let effectView = UIVisualEffectView(effect: nil)
    private var intensityAnimator: UIViewPropertyAnimator?

    private let maskContainer = UIView()
    private let maskImageLayer = CALayer()
    private let screenHolesLayer = CAShapeLayer()

    private var maskMapRect = MKMapRect.null
    private var maskScreenScale: Double = 0
    private var maskCloudLevel = -1
    /// Blur strength under bare haze, relative to under a dense fog bank.
    private let hazeBlurFraction: CGFloat = 0.45
    private var needsMaskRender = true

    private let softHole: CGImage? = FogBlurView.makeSoftHole(size: 64)

    init(intensity: CGFloat = 0.08) {
        self.intensity = intensity
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false

        effectView.frame = bounds
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.isUserInteractionEnabled = false
        addSubview(effectView)

        maskImageLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        maskImageLayer.magnificationFilter = .linear
        maskContainer.layer.addSublayer(maskImageLayer)

        // Everything inside the even-odd path (the full view minus each hole)
        // stays visible; holes punch through to the sharp map.
        screenHolesLayer.fillRule = .evenOdd
        screenHolesLayer.fillColor = UIColor.black.cgColor
        screenHolesLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        maskContainer.layer.mask = screenHolesLayer

        effectView.mask = maskContainer
        applyIntensity()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        intensityAnimator?.stopAnimation(true)
    }

    /// The intensity animator only holds its fraction once the effect view is
    /// in a window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyIntensity() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        maskContainer.frame = bounds
        screenHolesLayer.frame = bounds
        mapDidMove()
    }

    /// Exploration changed: re-render the mask, cross-fading so newly cleared
    /// ground sharpens at the same pace the fog over it fades.
    func explorationDidChange(animated: Bool) {
        needsMaskRender = true
        renderMaskIfNeeded(fadeDuration: animated ? 0.9 : 0)
    }

    /// Call on every camera change. Cheap unless the mask needs re-rendering.
    func mapDidMove() {
        guard let mapView, bounds.width > 0 else { return }
        let visible = mapView.visibleMapRect
        guard visible.size.width > 0 else { return }
        let screenScale = Double(bounds.width) / visible.size.width

        if !needsMaskRender, !maskMapRect.isNull, maskScreenScale > 0 {
            let zoomRatio = screenScale / maskScreenScale
            if !maskMapRect.contains(visible) || zoomRatio > 1.5 || zoomRatio < 0.67
                || CloudField.level(forZoomScale: screenScale) != maskCloudLevel
            {
                needsMaskRender = true
            }
        }
        renderMaskIfNeeded(fadeDuration: 0)
        positionMask(visible: visible, screenScale: screenScale)
        updateScreenHoles()
    }

    // MARK: - Mask

    private func renderMaskIfNeeded(fadeDuration: CFTimeInterval) {
        guard needsMaskRender, let mapView, bounds.width > 0 else { return }
        let visible = mapView.visibleMapRect
        guard visible.size.width > 0 else { return }
        needsMaskRender = false

        // Render half a screen of margin on every side so ordinary pans don't
        // trigger a re-render.
        let rect = visible.insetBy(dx: -visible.size.width * 0.5, dy: -visible.size.height * 0.5)
        let screenScale = Double(bounds.width) / visible.size.width
        let pixelsPerMapPoint = screenScale * Double(maskResolution)
        let width = max(Int((rect.size.width * pixelsPerMapPoint).rounded(.up)), 1)
        let height = max(Int((rect.size.height * pixelsPerMapPoint).rounded(.up)), 1)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // y-down to match map space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .low

        // Light blur under bare haze, full blur under the fog banks, using the
        // same banks (and the same "already cleared" test) as the tile renderer.
        context.setFillColor(UIColor(white: 1, alpha: hazeBlurFraction).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let level = CloudField.level(forZoomScale: screenScale)
        let cleared = clearedGeometriesProvider?(rect.insetBy(
            dx: -CloudField.clearRadius(level: level),
            dy: -CloudField.clearRadius(level: level)
        )) ?? []
        let clearCircles = FogRenderer.clearCircles(for: cleared, clearRadius: CloudField.clearRadius(level: level))
        let atlas = CloudSpriteAtlas.shared
        let k = CGFloat(pixelsPerMapPoint)
        for cloud in CloudField.clouds(intersecting: rect, level: level) {
            guard let image = atlas.image(at: cloud.spriteIndex),
                  !FogRenderer.isCloudCleared(cloud, among: clearCircles)
            else { continue }
            context.saveGState()
            context.translateBy(
                x: CGFloat(cloud.centerX - rect.minX) * k,
                y: CGFloat(cloud.centerY - rect.minY) * k
            )
            context.rotate(by: cloud.rotation)
            context.scaleBy(x: cloud.isFlipped ? -1 : 1, y: -1)
            context.setAlpha(min(cloud.opacity * 1.2, 1))
            let w = CGFloat(cloud.width) * k, h = CGFloat(cloud.height) * k
            context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            context.restoreGState()
        }
        if let softHole, !cleared.isEmpty {
            context.setBlendMode(.destinationOut)
            for geometry in cleared {
                let center = geometry.centerMapPoint
                var radius = 0.0
                for vertex in geometry.boundary {
                    radius = max(radius, hypot(vertex.x - center.x, vertex.y - center.y))
                }
                let pixelRadius = radius * clearRadiusScale * pixelsPerMapPoint
                guard pixelRadius >= 0.5 else { continue }
                let x = (center.x - rect.minX) * pixelsPerMapPoint
                let y = (center.y - rect.minY) * pixelsPerMapPoint
                context.draw(softHole, in: CGRect(
                    x: x - pixelRadius,
                    y: y - pixelRadius,
                    width: pixelRadius * 2,
                    height: pixelRadius * 2
                ))
            }
        }

        guard let image = context.makeImage() else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fadeDuration > 0, maskImageLayer.contents != nil {
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            maskImageLayer.add(fade, forKey: "contents")
        }
        maskImageLayer.contents = image
        CATransaction.commit()

        maskMapRect = rect
        maskScreenScale = screenScale
        maskCloudLevel = level
    }

    private func positionMask(visible: MKMapRect, screenScale: Double) {
        guard !maskMapRect.isNull else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskImageLayer.frame = CGRect(
            x: (maskMapRect.minX - visible.minX) * screenScale,
            y: (maskMapRect.minY - visible.minY) * screenScale,
            width: maskMapRect.size.width * screenScale,
            height: maskMapRect.size.height * screenScale
        )
        CATransaction.commit()
    }

    /// Keeps quest pins (with their label pills) and MapKit's legal
    /// attribution out of the blur.
    private func updateScreenHoles() {
        guard let mapView else { return }
        let path = UIBezierPath(rect: bounds)

        for annotation in mapView.annotations where annotation is QuestAnnotation {
            guard let view = mapView.view(for: annotation), !view.isHidden else { continue }
            var extent = view.bounds
            for subview in view.subviews where !subview.isHidden && subview.alpha > 0.01 {
                extent = extent.union(subview.frame)
            }
            let frame = view.convert(extent, to: self).insetBy(dx: -6, dy: -6)
            guard frame.intersects(bounds) else { continue }
            path.append(UIBezierPath(roundedRect: frame, cornerRadius: 18))
        }

        for subview in mapView.subviews {
            let name = String(describing: type(of: subview))
            guard name.contains("Attribution") || name.contains("Legal") || name.contains("Logo") else { continue }
            path.append(UIBezierPath(rect: subview.convert(subview.bounds, to: self).insetBy(dx: -4, dy: -4)))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenHolesLayer.path = path.cgPath
        CATransaction.commit()
    }

    // MARK: - Blur strength

    /// `UIVisualEffectView` has no public radius, so the blur is applied via a
    /// paused animator scrubbed to `intensity`.
    private func applyIntensity() {
        intensityAnimator?.stopAnimation(true)
        effectView.effect = nil
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [effectView] in
            effectView.effect = UIBlurEffect(style: .light)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = intensity
        intensityAnimator = animator
    }

    /// The system can finish paused animators while the app is backgrounded,
    /// which would snap the blur to full strength.
    @objc private func appDidBecomeActive() {
        applyIntensity()
    }

    private static func makeSoftHole(size: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) else { return nil }

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
