import MapKit
import SwiftUI
import UIKit
import FogKit

/// Where a sticker is drawn: its center and how many screen points it gets per
/// design point (`BoardSticker.size` is in design points).
struct StickerPlacement: Equatable {
    var center: CGPoint
    var scale: CGFloat
}

/// Positions from the sticker stats Figma frame (10:46, "Route Summary"),
/// measured from the top-left of the 403 pt wide profile sheet. Horizontal
/// values scale with the sheet's width; vertical ones stay in points.
enum StickerStatsLayout {
    static let designWidth: CGFloat = 403

    /// The sticker's rotated bounding box (Figma 10:61) and its center.
    static let heroCenter = CGPoint(x: 205.8, y: 128.76)
    static let heroBounds = CGSize(width: 265.599, height: 207.517)

    /// Blurred copy of the sticker art behind everything (Figma "Map Image" 10:59):
    /// 3.8× the sticker, centered a little right of and above it.
    static let backdropScale: CGFloat = 900.311 / 235.897
    static let backdropOffset = CGSize(width: 7.04, height: -28.76)
    static let backdropBlur: CGFloat = 188.863

    /// Dot pattern across the top of the sheet (Figma "Map Background" 10:60).
    static let dotFieldHeight: CGFloat = 357

    static let distanceLabel = CGPoint(x: 87.28, y: 234)
    static let distanceValueCenterX: CGFloat = 119.5
    static let timeLabel = CGPoint(x: 258.11, y: 234)
    static let timeValueCenterX: CGFloat = 276.72
    static let valueTop: CGFloat = 248

    /// The route map (Figma 10:80), wider than the sheet so its blurred edges bleed off.
    static let mapFrame = CGRect(x: -5, y: 269, width: 413, height: 495)
    /// Where the route itself sits inside the map (Figma vector 14:91).
    static let routeInsets = EdgeInsets(top: 153, leading: 94.5, bottom: 109, trailing: 98)
    /// Height of the route inside the map (495 − 153 − 109).
    static let routeHeight: CGFloat = 233
    /// How far the map runs past the bottom of the sheet, so its faded edge is offscreen.
    static let mapBottomBleed: CGFloat = 70

    static func widthScale(_ width: CGFloat) -> CGFloat { width / designWidth }

    /// The sticker at rest in the stats view: fitted, rotated, into Figma's hero box.
    static func heroPlacement(for sticker: BoardSticker, width: CGFloat) -> StickerPlacement {
        let k = widthScale(width)
        let angle = sticker.rotation * .pi / 180
        let cosA = abs(CGFloat(cos(angle))), sinA = abs(CGFloat(sin(angle)))
        let rotatedWidth = sticker.size.width * cosA + sticker.size.height * sinA
        let rotatedHeight = sticker.size.width * sinA + sticker.size.height * cosA
        let scale = min(
            heroBounds.width * k / max(rotatedWidth, 1),
            heroBounds.height / max(rotatedHeight, 1)
        )
        return StickerPlacement(center: CGPoint(x: heroCenter.x * k, y: heroCenter.y), scale: scale)
    }
}

/// The holographic sticker that flies between the memory board and the stats
/// view. It keeps the drag-to-tilt reflections of `HolographicStickerView`.
struct StickerHeroView: View {
    let sticker: BoardSticker
    /// Where to draw it now (animated between the board and the hero spot).
    let placement: StickerPlacement
    /// Scale the artwork and outline are rendered at (the hero spot's), so the
    /// outline stays sharp where the sticker comes to rest.
    let restScale: CGFloat
    let movement: CGSize

    var body: some View {
        let canvas = CGSize(width: sticker.size.width * restScale, height: sticker.size.height * restScale)
        let outline = sticker.outline * restScale
        let pad = StickerOutline.padding(for: outline)
        let art = CGRect(
            x: sticker.imageRect.minX * canvas.width,
            y: sticker.imageRect.minY * canvas.height,
            width: sticker.imageRect.width * canvas.width,
            height: sticker.imageRect.height * canvas.height
        )

        if let image = sticker.uiImage {
            HolographicStickerView(
                image: image,
                identifier: sticker.id,
                maximumSize: CGSize(width: art.width + pad * 2, height: art.height + pad * 2),
                outlineWidth: outline,
                accessibilityLabel: "\(sticker.accessibilityName) holographic sticker",
                translationLimit: movement
            )
            // Same art position inside the sticker frame as on the board, so the
            // hand-off from the board is seamless.
            .offset(x: art.midX - canvas.width / 2, y: art.midY - canvas.height / 2)
            .frame(width: canvas.width, height: canvas.height)
            .rotationEffect(.degrees(sticker.rotation))
            .scaleEffect(placement.scale / max(restScale, 0.01))
            .position(placement.center)
        }
    }
}

/// Sticker stats (Figma 10:46), shown inside the profile sheet: the walk's
/// distance and time over its route. The sticker itself is drawn by
/// `StickerHeroView` on top so it can fly in from the board.
struct StickerStatsView: View {
    let sticker: BoardSticker
    let expedition: ExpeditionSummary?
    /// When the sticker was collected; shown small at the bottom of the page.
    let date: Date?
    let onDismiss: () -> Void
    /// Height kept clear at the bottom for a caller's button (the quest's "Done"); the date sits above it.
    var footerInset: CGFloat = 0

    private static let ink = Color(red: 0x3B / 255, green: 0x3B / 255, blue: 0x3B / 255)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let k = StickerStatsLayout.widthScale(width)
            // The map runs off the bottom of the screen (its blurred edge is cut
            // off there) instead of fading out above a flat strip.
            let mapHeight = max(
                StickerStatsLayout.mapFrame.height,
                proxy.size.height - StickerStatsLayout.mapFrame.minY + StickerStatsLayout.mapBottomBleed
            )

            ZStack(alignment: .topLeading) {
                backdrop(width: width)

                RecapDotField()
                    .frame(width: width, height: StickerStatsLayout.dotFieldHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6.572, style: .continuous))

                routeMap(k: k, height: mapHeight)
                    .frame(
                        width: StickerStatsLayout.mapFrame.width * k,
                        height: mapHeight
                    )
                    .offset(
                        x: StickerStatsLayout.mapFrame.minX * k,
                        y: StickerStatsLayout.mapFrame.minY
                    )

                stat(
                    label: "Distance",
                    value: formattedDistance,
                    labelOrigin: StickerStatsLayout.distanceLabel,
                    valueCenterX: StickerStatsLayout.distanceValueCenterX,
                    k: k
                )
                stat(
                    label: "Time",
                    value: formattedDuration,
                    labelOrigin: StickerStatsLayout.timeLabel,
                    valueCenterX: StickerStatsLayout.timeValueCenterX,
                    k: k
                )
            }
            .overlay(alignment: .topTrailing) {
                closeButton
                    .padding(.top, 12)
                    .padding(.trailing, 18)
            }
            .overlay(alignment: .bottom) {
                // A soft fade keeps the date readable over the map.
                LinearGradient(
                    colors: [SideQuestDesign.profileSurface.opacity(0), SideQuestDesign.profileSurface.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                dateLabel
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 20) + 8 + footerInset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        // Cover the home-indicator area too, so the page reaches the screen's bottom edge.
        .ignoresSafeArea(.container, edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityAction(named: "Back to profile", onDismiss)
    }

    @ViewBuilder
    private var dateLabel: some View {
        if let date {
            Text(date.formatted(.dateTime.month(.wide).day().year()))
                .font(SideQuestDesign.ptSans(fixed: 14))
                .tracking(-0.3)
                .foregroundStyle(Self.ink.opacity(0.6))
                .allowsHitTesting(false)
        }
    }

    /// A dark ×; the sticker flies back to the board.
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SideQuestDesign.canvas)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close sticker")
    }

    // MARK: Backdrop

    /// The sticker art, hugely blurred, tints the top of the sheet in its colors.
    @ViewBuilder
    private func backdrop(width: CGFloat) -> some View {
        if let artwork = sticker.uiImage {
            let hero = StickerStatsLayout.heroPlacement(for: sticker, width: width)
            let k = StickerStatsLayout.widthScale(width)
            let size = CGSize(
                width: sticker.size.width * hero.scale * StickerStatsLayout.backdropScale,
                height: sticker.size.height * hero.scale * StickerStatsLayout.backdropScale
            )
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .blur(radius: StickerStatsLayout.backdropBlur)
                .rotationEffect(.degrees(sticker.rotation))
                .position(
                    x: hero.center.x + StickerStatsLayout.backdropOffset.width * k,
                    y: hero.center.y + StickerStatsLayout.backdropOffset.height
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Stats

    private func stat(
        label: String,
        value: String,
        labelOrigin: CGPoint,
        valueCenterX: CGFloat,
        k: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Text(label)
                .font(SideQuestDesign.ptSans(fixed: 17))
                .tracking(-0.51)
                .fixedSize()
                .offset(x: labelOrigin.x * k, y: labelOrigin.y)

            Text(value)
                .font(SideQuestDesign.calSans(38.911, relativeTo: nil))
                .tracking(-0.3891)
                .fixedSize()
                // Centered on `valueCenterX`, like Figma's -translate-x-1/2.
                .frame(width: 0)
                .offset(x: valueCenterX * k, y: StickerStatsLayout.valueTop)
        }
        .foregroundStyle(Self.ink)
        .accessibilityElement(children: .combine)
    }

    private var formattedDistance: String {
        guard let meters = expedition?.distanceMeters else { return "—" }
        let kilometers = max(meters, 0) / 1_000
        let value = kilometers >= 10
            ? Int(kilometers.rounded()).formatted()
            : kilometers.formatted(.number.precision(.fractionLength(kilometers == 0 ? 0 : 1)))
        return "\(value) km"
    }

    private var formattedDuration: String {
        guard let duration = expedition?.duration else { return "—" }
        let totalMinutes = max(Int(duration / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: Route

    @ViewBuilder
    private func routeMap(k: CGFloat, height: CGFloat) -> some View {
        let segments = expedition?.segments.filter { $0.count >= 2 } ?? []
        if let expedition, !segments.isEmpty {
            RouteSnapshotMap(
                segments: segments,
                size: CGSize(width: StickerStatsLayout.mapFrame.width * k, height: height),
                // The route keeps its Figma position (top inset, fixed height) however tall the map is.
                routeInsets: EdgeInsets(
                    top: StickerStatsLayout.routeInsets.top,
                    leading: StickerStatsLayout.routeInsets.leading * k,
                    bottom: height - StickerStatsLayout.routeInsets.top - StickerStatsLayout.routeHeight,
                    trailing: StickerStatsLayout.routeInsets.trailing * k
                )
            )
            .id(expedition.id)
            .organicEdgeBlur()
            .accessibilityLabel("Route walked during this expedition")
        } else {
            VStack(spacing: 9) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.system(size: 24, weight: .medium))
                Text("No route recorded for this sticker")
                    .font(SideQuestDesign.ptSans(fixed: 15))
            }
            .foregroundStyle(Self.ink.opacity(0.38))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A still map of the route (Figma's map image + coral route line), drawn
/// once with `MKMapSnapshotter` so the shader can run over it.
private struct RouteSnapshotMap: View {
    let segments: [[Coordinate]]
    let size: CGSize
    /// Where the route's bounding box should land inside the map.
    let routeInsets: EdgeInsets

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private static let routeColor = UIColor(red: 0xFF / 255, green: 0x62 / 255, blue: 0x57 / 255, alpha: 1)
    private static let routeWidth: CGFloat = 5
    /// Short walks still show a neighbourhood, not a few houses.
    private static let minimumSpanMeters: Double = 420

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: RenderKey(width: Int(size.width), height: Int(size.height), scale: displayScale)) {
            guard let rendered = await render() else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = rendered }
        }
        .allowsHitTesting(false)
    }

    private struct RenderKey: Hashable {
        var width: Int
        var height: Int
        var scale: CGFloat
    }

    private func render() async -> UIImage? {
        guard size.width > 1, size.height > 1, let rect = mapRect else { return nil }

        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(displayScale: displayScale),
        ])

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext
            cg.setStrokeColor(Self.routeColor.cgColor)
            cg.setLineWidth(Self.routeWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for segment in segments {
                let points = segment.map { snapshot.point(for: $0.clCoordinate) }
                guard let first = points.first else { continue }
                cg.beginPath()
                cg.move(to: first)
                for point in points.dropFirst() { cg.addLine(to: point) }
                cg.strokePath()
            }
        }
    }

    /// Fits the route's bounding box into `routeInsets`, keeping the map's aspect.
    private var mapRect: MKMapRect? {
        let coordinates = segments.flatMap { $0 }
        guard let first = coordinates.first else { return nil }
        let points = coordinates.map { MKMapPoint($0.clCoordinate) }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0

        let inner = CGSize(
            width: max(size.width - routeInsets.leading - routeInsets.trailing, 1),
            height: max(size.height - routeInsets.top - routeInsets.bottom, 1)
        )
        let minimumSpan = MKMapPointsPerMeterAtLatitude(first.latitude) * Self.minimumSpanMeters
        // Map points per screen point.
        let density = max(
            (maxX - minX) / Double(inner.width),
            (maxY - minY) / Double(inner.height),
            minimumSpan / Double(inner.width)
        )
        let innerCenter = CGPoint(
            x: routeInsets.leading + inner.width / 2,
            y: routeInsets.top + inner.height / 2
        )
        return MKMapRect(
            x: (minX + maxX) / 2 - Double(innerCenter.x) * density,
            y: (minY + maxY) / 2 - Double(innerCenter.y) * density,
            width: Double(size.width) * density,
            height: Double(size.height) * density
        )
    }
}

extension View {
    /// Figma's "Organic edge blur" effect (`OrganicEdgeBlur.metal`) with the
    /// sticker stats map's parameters: wavy edges that blur as they fade out.
    func organicEdgeBlur(
        blurStrength: Float = 17.5,
        edgeWidth: Float = 28,
        falloff: Float = 1.4,
        wavesOn: Bool = true,
        waveAmount: Float = 26,
        waveScale: Float = 72
    ) -> some View {
        // Farthest blur tap: sqrt(-2 ln 0.01) ≈ 3.04 standard deviations.
        let reach = CGFloat(blurStrength) * 3.04 + 1
        return visualEffect { content, proxy in
            content.layerEffect(
                ShaderLibrary.organicEdgeBlur(
                    .float2(proxy.size),
                    .float(blurStrength),
                    .float(edgeWidth),
                    .float(falloff),
                    .float(wavesOn ? 1 : 0),
                    .float(waveAmount),
                    .float(waveScale)
                ),
                maxSampleOffset: CGSize(width: reach, height: reach)
            )
        }
    }
}

/// Figma's quiet white dot texture across the top of the sheet.
struct RecapDotField: View {
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let spacing: CGFloat = 10.7328
            let radius: CGFloat = 1.45
            var path = Path()
            for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
            context.fill(path, with: .color(.white.opacity(0.16)))
        }
        .allowsHitTesting(false)
    }
}
