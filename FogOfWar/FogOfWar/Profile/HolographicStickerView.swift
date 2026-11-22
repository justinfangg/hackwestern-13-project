import MapKit
import SwiftUI
import UIKit
import FogKit

/// Sticker detail content that lives inside Jonathan's existing profile panel.
/// The app's real map and divider remain owned by `MainView`, so this view has
/// one continuous blush surface instead of presenting a disconnected map strip.
struct HolographicStickerDetailView: View {
    let sticker: BoardSticker
    let collectedSticker: Sticker?
    let expedition: ExpeditionSummary?
    let isSample: Bool
    let onDismiss: () -> Void

    init(
        sticker: BoardSticker,
        collectedSticker: Sticker? = nil,
        expedition: ExpeditionSummary? = nil,
        isSample: Bool = false,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.sticker = sticker
        self.collectedSticker = collectedSticker
        self.expedition = expedition
        self.isSample = isSample
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = DetailMetrics(size: proxy.size)

            ZStack(alignment: .topTrailing) {
                SideQuestDesign.profileSurface
                blushBackdrop(size: proxy.size)

                RecapDotField()
                    .frame(height: metrics.dotFieldHeight)
                    .opacity(0.9)
                    .frame(maxHeight: .infinity, alignment: .top)

                if expedition != nil {
                    expeditionLayout(metrics: metrics)
                } else {
                    stickerOnlyLayout(metrics: metrics)
                }

                if isSample {
                    Text("SAMPLE DATA")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(Self.ink.opacity(0.62))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.white.opacity(0.70), in: Capsule())
                        .padding(.top, metrics.edgePadding + 6)
                        .padding(.trailing, metrics.edgePadding + 48)
                        .accessibilityLabel("Sample data")
                }

                closeButton
                    .padding(.top, metrics.edgePadding)
                    .padding(.trailing, metrics.edgePadding)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background {
            SideQuestDesign.profileSurface
                .ignoresSafeArea()
        }
        .accessibilityAction(.escape) { onDismiss() }
    }

    private func expeditionLayout(metrics: DetailMetrics) -> some View {
        VStack(spacing: 0) {
            stickerHero(
                maximumSize: metrics.recapStickerSize(for: sticker),
                movement: metrics.recapMovement(for: sticker)
            )
            .frame(height: metrics.recapHeroHeight)
            .frame(maxWidth: .infinity)
            .clipped()

            stats
                .padding(.horizontal, metrics.statsHorizontalPadding)
                .frame(height: metrics.statsHeight, alignment: .top)
                .zIndex(2)

            routeLayer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .padding(.top, metrics.contentTopPadding)
        .padding(.bottom, metrics.bottomPadding)
    }

    private func stickerOnlyLayout(metrics: DetailMetrics) -> some View {
        VStack(spacing: 0) {
            stickerHero(
                maximumSize: metrics.focusStickerSize(for: sticker),
                movement: metrics.focusMovement(for: sticker)
            )
            .frame(height: metrics.focusHeroHeight)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(spacing: metrics.compactSpacing) {
                Text(sticker.accessibilityName)
                    .font(SideQuestDesign.calSans(metrics.titleSize, relativeTo: nil))
                    .tracking(-0.3)
                    .foregroundStyle(Self.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text("Holographic collectible")
                    .font(SideQuestDesign.ptSans(fixed: 17))
                    .tracking(-0.35)
                    .foregroundStyle(Self.ink.opacity(0.62))

                metadata
                    .padding(.top, metrics.compactSpacing)

                Label("Drag to move, tilt, and catch the light", systemImage: "hand.draw.fill")
                    .font(SideQuestDesign.ptSans(fixed: 14))
                    .foregroundStyle(Self.ink.opacity(0.54))
                    .padding(.top, metrics.compactSpacing)
            }
            .padding(.horizontal, metrics.metadataHorizontalPadding)
            .padding(.vertical, metrics.metadataVerticalPadding)
            .frame(maxWidth: metrics.metadataMaximumWidth)
            .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1)
            }

            Spacer(minLength: metrics.bottomPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.edgePadding)
        .padding(.top, metrics.contentTopPadding)
    }

    @ViewBuilder
    private func stickerHero(maximumSize: CGSize, movement: CGSize) -> some View {
        if let artwork = UIImage(named: sticker.imageName) {
            HolographicStickerView(
                image: artwork,
                identifier: sticker.id,
                maximumSize: maximumSize,
                outlineWidth: sticker.outline,
                accessibilityLabel: "\(sticker.accessibilityName) holographic sticker",
                translationLimit: movement
            )
        } else {
            ContentUnavailableView(
                "Sticker unavailable",
                systemImage: "photo",
                description: Text("The sticker artwork could not be loaded.")
            )
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 24) {
            recapStat(label: "Distance", value: formattedDistance)
            recapStat(label: "Time", value: formattedDuration)
        }
    }

    private func recapStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(SideQuestDesign.ptSans(fixed: 17))
                .tracking(-0.51)
            Text(value)
                .font(SideQuestDesign.calSans(38, relativeTo: nil))
                .tracking(-0.38)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(Color(red: 0.23, green: 0.23, blue: 0.23))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func blushBackdrop(size: CGSize) -> some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 1.00, green: 0.56, blue: 0.61).opacity(0.30),
                    Color(red: 1.00, green: 0.76, blue: 0.64).opacity(0.16),
                    .clear
                ],
                center: UnitPoint(x: 0.82, y: 0.42),
                startRadius: 12,
                endRadius: max(size.width, size.height) * 0.34
            )

            RadialGradient(
                colors: [
                    Color(red: 0.98, green: 0.63, blue: 0.72).opacity(0.18),
                    .clear
                ],
                center: UnitPoint(x: 0.20, y: 0.68),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.31
            )

            if let artwork = UIImage(named: sticker.imageName) {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width * 2.18, height: size.height * 0.78)
                    .rotationEffect(.degrees(sticker.rotation))
                    .blur(radius: min(max(size.width * 0.18, 48), 76))
                    .opacity(0.19)
                    .offset(x: size.width * 0.34, y: size.height * 0.12)
                    .saturation(1.2)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var routeLayer: some View {
        let drawableSegments = expedition?.segments.filter { $0.count >= 2 } ?? []
        if let expedition, !drawableSegments.isEmpty {
            RecapRouteMap(segments: drawableSegments)
                .id(expedition.id)
                .opacity(0.76)
                .blur(radius: 0.35)
                .mask(routeFade)
                .accessibilityLabel("Route walked during this expedition")
        } else {
            VStack(spacing: 9) {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.system(size: 24, weight: .medium))
                Text("This expedition has no recorded route")
                    .font(SideQuestDesign.ptSans(fixed: 15))
            }
            .foregroundStyle(Color(red: 0.23, green: 0.23, blue: 0.23).opacity(0.38))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private var routeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.8), location: 0.12),
                .init(color: .black, location: 0.32),
                .init(color: .black.opacity(0.95), location: 0.82),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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

    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { metadataItems }
            VStack(spacing: 8) { metadataItems }
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        metadataPill(icon: "checkmark.seal.fill", text: "Collected")

        if let placeName = collectedSticker?.placeName, !placeName.isEmpty {
            metadataPill(icon: "mappin.and.ellipse", text: placeName)
        } else if let category = collectedSticker?.category, !category.isEmpty {
            metadataPill(icon: "tag.fill", text: category.capitalized)
        } else {
            metadataPill(icon: "square.grid.2x2.fill", text: "In your sticker collection")
        }

        if let collectedAt = collectedSticker?.collectedAt {
            metadataPill(
                icon: "calendar",
                text: collectedAt.formatted(.dateTime.month(.abbreviated).day().year())
            )
        }
    }

    private func metadataPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(SideQuestDesign.ptSans(fixed: 14))
            .foregroundStyle(Self.ink.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.white.opacity(0.68), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.72), lineWidth: 1) }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Self.ink)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.82), in: Circle())
                .overlay { Circle().strokeBorder(.black.opacity(0.06), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close sticker")
        .zIndex(10)
    }

    private static let ink = Color(red: 0.23, green: 0.23, blue: 0.23)

    private struct DetailMetrics {
        let size: CGSize

        private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(max(value, lower), upper)
        }

        var edgePadding: CGFloat { clamp(size.width * 0.06, 20, 28) }
        var contentTopPadding: CGFloat { clamp(size.height * 0.025, 14, 22) }
        var bottomPadding: CGFloat { clamp(size.height * 0.025, 14, 24) }
        var dotFieldHeight: CGFloat { min(size.height * 0.52, 357) }

        var recapHeroHeight: CGFloat { clamp(size.height * 0.29, 190, 230) }
        var statsHeight: CGFloat { clamp(size.height * 0.115, 76, 88) }
        var statsHorizontalPadding: CGFloat { clamp(size.width * 0.17, 48, 70) }

        var focusHeroHeight: CGFloat { clamp(size.height * 0.54, 300, 420) }
        var titleSize: CGFloat { clamp(size.width * 0.075, 26, 32) }
        var compactSpacing: CGFloat { clamp(size.height * 0.010, 6, 10) }
        var metadataHorizontalPadding: CGFloat { clamp(size.width * 0.055, 18, 26) }
        var metadataVerticalPadding: CGFloat { clamp(size.height * 0.024, 14, 22) }
        var metadataMaximumWidth: CGFloat { min(size.width - edgePadding * 2, 370) }

        func recapStickerSize(for sticker: BoardSticker) -> CGSize {
            let scale = clamp(size.width / 402, 0.82, 1.08)
            let desired = CGSize(width: sticker.size.width * scale, height: sticker.size.height * scale)
            return fitted(desired, inside: CGSize(width: size.width * 0.70, height: recapHeroHeight * 0.80))
        }

        func focusStickerSize(for sticker: BoardSticker) -> CGSize {
            let scale = clamp(size.width / 402 * 1.28, 1.02, 1.38)
            let desired = CGSize(width: sticker.size.width * scale, height: sticker.size.height * scale)
            return fitted(desired, inside: CGSize(width: size.width * 0.82, height: focusHeroHeight * 0.72))
        }

        func recapMovement(for sticker: BoardSticker) -> CGSize {
            let stickerSize = recapStickerSize(for: sticker)
            return CGSize(
                width: max(0, min(48, (size.width - stickerSize.width) / 2 - 16)),
                height: max(0, min(18, (recapHeroHeight - stickerSize.height) / 2 - 14))
            )
        }

        func focusMovement(for sticker: BoardSticker) -> CGSize {
            let stickerSize = focusStickerSize(for: sticker)
            return CGSize(
                width: max(0, min(50, (size.width - stickerSize.width) / 2 - 14)),
                height: max(0, min(32, (focusHeroHeight - stickerSize.height) / 2 - 16))
            )
        }

        private func fitted(_ desired: CGSize, inside bounds: CGSize) -> CGSize {
            guard desired.width > 0, desired.height > 0 else { return bounds }
            let scale = min(bounds.width / desired.width, bounds.height / desired.height, 1)
            return CGSize(width: desired.width * scale, height: desired.height * scale)
        }
    }
}

/// The mockup's quiet white dot texture, rendered once and clipped by the panel.
private struct RecapDotField: View {
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

/// A recap-only map. It consumes the selected expedition's real route and does
/// not participate in the app's FogMapView, exploration store, or H3 renderer.
private struct RecapRouteMap: View {
    let segments: [[Coordinate]]

    var body: some View {
        Map(initialPosition: .rect(visibleRect), interactionModes: []) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.map(\.clCoordinate))
                    .stroke(
                        Color(red: 1, green: 0.38, blue: 0.34),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
    }

    private var visibleRect: MKMapRect {
        let coordinates = segments.flatMap { $0 }.map(\.clCoordinate)
        guard let first = coordinates.first else { return .world }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let minimumSpan = MKMapPointsPerMeterAtLatitude(first.latitude) * 420
        let width = max((maxX - minX) * 1.38, minimumSpan)
        let height = max((maxY - minY) * 1.38, minimumSpan)
        return MKMapRect(
            x: (minX + maxX - width) / 2,
            y: (minY + maxY - height) / 2,
            width: width,
            height: height
        )
    }
}

/// A reusable, gesture-driven holographic finish for transparent photographic artwork.
///
/// The original photo remains the base layer. Every optical layer is masked by
/// the source PNG's alpha, while the cached white die-cut outline stays clean.
/// There is deliberately no timeline or repeating animation: this view only
/// redraws for a drag and its one-shot return spring.
struct HolographicStickerView: View {
    let image: UIImage
    let identifier: String
    let maximumSize: CGSize
    let outlineWidth: CGFloat
    let accessibilityLabel: String
    /// Maximum center movement from rest. A zero limit keeps the renderer in
    /// tilt-only mode for callers that do not provide a physical play area.
    let translationLimit: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var outlinedImage: UIImage?
    @State private var tilt = CGSize.zero
    @State private var displacement = CGSize.zero
    @State private var dragOrigin: CGSize?
    @State private var isDragging = false
    @State private var releaseGeneration = 0

    private static let maximumRenderSide: CGFloat = 2400

    init(
        image: UIImage,
        identifier: String,
        maximumSize: CGSize,
        outlineWidth: CGFloat,
        accessibilityLabel: String,
        translationLimit: CGSize = .zero
    ) {
        self.image = image
        self.identifier = identifier
        self.maximumSize = maximumSize
        self.outlineWidth = outlineWidth
        self.accessibilityLabel = accessibilityLabel
        self.translationLimit = translationLimit
    }

    var body: some View {
        let artSize = fittedArtworkSize
        let pad = StickerOutline.padding(for: outlineWidth)
        let outerSize = CGSize(width: artSize.width + pad * 2, height: artSize.height + pad * 2)
        let opticalTilt = reduceMotion
            ? CGSize(width: tilt.width * 0.38, height: tilt.height * 0.38)
            : tilt

        stickerSurface(artSize: artSize, outerSize: outerSize, opticalTilt: opticalTilt)
            .frame(width: outerSize.width, height: outerSize.height)
            .contentShape(Rectangle())
            .rotation3DEffect(
                perspectiveAngle,
                axis: perspectiveAxis,
                anchor: .center,
                perspective: 0.55
            )
            .rotationEffect(reduceMotion ? .zero : .degrees(Double(tilt.width * 2.2)))
            .scaleEffect(isDragging && !reduceMotion ? 1.014 : 1)
            .shadow(
                color: .black.opacity(isDragging ? 0.35 : 0.31),
                radius: isDragging ? 24 : 20,
                x: -opticalTilt.width * 7,
                y: isDragging ? 7 - opticalTilt.height * 4 : 1
            )
            .offset(displacement)
            .gesture(physicalDragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(
                reduceMotion
                    ? "Drag to move the sticker and reflected light"
                    : "Drag to move and tilt the sticker, then release it to spring back"
            )
            .accessibilityAddTraits(.isImage)
            .task(id: outlineRenderKey) {
                await renderOutline(artSize: artSize)
            }
            .onChange(of: reduceMotion) { _, enabled in
                guard enabled else { return }
                releaseGeneration &+= 1
                tilt = .zero
                displacement = .zero
                dragOrigin = nil
                isDragging = false
            }
    }

    private var fittedArtworkSize: CGSize {
        let pad = StickerOutline.padding(for: outlineWidth) * 2
        let available = CGSize(
            width: max(maximumSize.width - pad, 1),
            height: max(maximumSize.height - pad, 1)
        )
        let source = image.size
        guard source.width > 0, source.height > 0 else { return available }

        let aspect = source.width / source.height
        if available.width / available.height > aspect {
            return CGSize(width: available.height * aspect, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / aspect)
    }

    private var outlineRenderKey: OutlineRenderKey {
        let size = fittedArtworkSize
        return OutlineRenderKey(
            identifier: identifier,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            thickness: Int((outlineWidth * 10).rounded()),
            scale: Int((displayScale * 100).rounded())
        )
    }

    private var perspectiveAngle: Angle {
        guard !reduceMotion else { return .zero }
        return .degrees(Double(hypot(tilt.width, tilt.height) * 13))
    }

    private var perspectiveAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        let length = hypot(tilt.width, tilt.height)
        guard length > 0.001, !reduceMotion else { return (x: 0, y: 1, z: 0) }
        return (x: -tilt.height / length, y: tilt.width / length, z: 0)
    }

    private func stickerSurface(artSize: CGSize, outerSize: CGSize, opticalTilt: CGSize) -> some View {
        ZStack {
            if let outlinedImage {
                Image(uiImage: outlinedImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: outerSize.width, height: outerSize.height)
                    .transition(.opacity)
            } else {
                // The exact Core Image outline replaces this as soon as the
                // cached render completes.
                sourceImage(size: artSize)
                    .shadow(color: .white.opacity(0.95), radius: outlineWidth * 0.72)
            }

            HolographicFoil(tilt: opticalTilt)
                .frame(width: artSize.width, height: artSize.height)
                .mask { sourceImage(size: artSize) }
                .blendMode(.screen)

            DirectionalSurfaceLight(tilt: opticalTilt)
                .frame(width: artSize.width, height: artSize.height)
                .mask { sourceImage(size: artSize) }
                .blendMode(.softLight)
        }
        .frame(width: outerSize.width, height: outerSize.height)
        .compositingGroup()
    }

    private func sourceImage(size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
    }

    private var physicalDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin == nil {
                    releaseGeneration &+= 1
                    dragOrigin = displacement
                }

                let origin = dragOrigin ?? .zero
                displacement = clampedDisplacement(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    )
                )
                tilt = Self.normalizedTilt(for: value.translation)
                isDragging = true
            }
            .onEnded { value in
                dragOrigin = nil
                releaseGeneration &+= 1
                let generation = releaseGeneration

                guard !reduceMotion else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        displacement = .zero
                        tilt = .zero
                        isDragging = false
                    }
                    return
                }

                let inertia = CGSize(
                    width: (value.predictedEndTranslation.width - value.translation.width) * 0.16,
                    height: (value.predictedEndTranslation.height - value.translation.height) * 0.16
                )
                let projected = clampedDisplacement(
                    CGSize(
                        width: displacement.width + inertia.width,
                        height: displacement.height + inertia.height
                    )
                )
                let projectedTilt = Self.normalizedTilt(
                    for: CGSize(
                        width: value.translation.width + inertia.width,
                        height: value.translation.height + inertia.height
                    )
                )

                withAnimation(.easeOut(duration: 0.10)) {
                    displacement = projected
                    tilt = projectedTilt
                }

                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(75))
                    guard releaseGeneration == generation else { return }
                    withAnimation(.spring(duration: 0.72, bounce: 0.28)) {
                        displacement = .zero
                        tilt = .zero
                        isDragging = false
                    }
                }
            }
    }

    private func clampedDisplacement(_ proposed: CGSize) -> CGSize {
        CGSize(
            width: min(max(proposed.width, -abs(translationLimit.width)), abs(translationLimit.width)),
            height: min(max(proposed.height, -abs(translationLimit.height)), abs(translationLimit.height))
        )
    }

    private static func normalizedTilt(for translation: CGSize) -> CGSize {
        var x = translation.width / 86
        var y = translation.height / 76
        let length = hypot(x, y)
        if length > 1 {
            x /= length
            y /= length
        }
        return CGSize(width: x, height: y)
    }

    private func renderOutline(artSize: CGSize) async {
        let image = image
        let identifier = identifier
        let outlineWidth = outlineWidth
        let longestSide = max(artSize.width, artSize.height) + outlineWidth * 2
        let renderScale = min(displayScale * 2.5, Self.maximumRenderSide / max(longestSide, 1))

        let rendered = await Task.detached(priority: .userInitiated) {
            StickerOutline.render(
                image,
                cacheKey: "holographic.\(identifier)",
                canvas: artSize,
                imageRect: CGRect(origin: .zero, size: artSize),
                thickness: outlineWidth,
                scale: renderScale
            )
        }.value

        guard !Task.isCancelled else { return }
        if reduceMotion {
            outlinedImage = rendered
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                outlinedImage = rendered
            }
        }
    }

    private struct OutlineRenderKey: Hashable {
        var identifier: String
        var width: Int
        var height: Int
        var thickness: Int
        var scale: Int
    }
}

/// Angle-dependent spectral bands, a narrow specular sweep, and deterministic
/// micro-grooves. `Animatable` lets the optical response share the return spring.
private struct HolographicFoil: View, Animatable {
    var tilt: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tilt.width, tilt.height) }
        set { tilt = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let response = min(hypot(tilt.width, tilt.height), 1)
            let lightCenter = UnitPoint(
                x: Self.clamp(0.5 + tilt.width * 0.42),
                y: Self.clamp(0.46 + tilt.height * 0.38)
            )

            ZStack {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: Color(red: 0.18, green: 0.86, blue: 0.94).opacity(0.25), location: 0.15),
                        .init(color: Color(red: 0.72, green: 0.42, blue: 0.96).opacity(0.23), location: 0.29),
                        .init(color: Color(red: 0.75, green: 0.86, blue: 1).opacity(0.15), location: 0.40),
                        .init(color: Color(red: 0.98, green: 0.35, blue: 0.62).opacity(0.24), location: 0.48),
                        .init(color: .clear, location: 0.60),
                        .init(color: Color(red: 0.96, green: 0.79, blue: 0.28).opacity(0.23), location: 0.74),
                        .init(color: Color(red: 0.35, green: 0.94, blue: 0.69).opacity(0.20), location: 0.86),
                        .init(color: .clear, location: 1.00),
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .scaleEffect(1.55)
                .rotationEffect(.degrees(-24 + Double(tilt.width * 24 - tilt.height * 16)))
                .offset(x: tilt.width * size.width * 0.26, y: tilt.height * size.height * 0.22)
                .opacity(0.50 + response * 0.16)

                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.cyan.opacity(0.23), location: 0.00),
                        .init(color: .clear, location: 0.18),
                        .init(color: Color.purple.opacity(0.22), location: 0.35),
                        .init(color: Color.pink.opacity(0.18), location: 0.52),
                        .init(color: .clear, location: 0.70),
                        .init(color: Color.yellow.opacity(0.19), location: 0.86),
                        .init(color: Color.cyan.opacity(0.23), location: 1.00),
                    ]),
                    center: lightCenter
                )
                .rotationEffect(.degrees(Double(tilt.width * 74 + tilt.height * 38)))
                .scaleEffect(1.18)
                .opacity(0.38 + response * 0.12)

                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 0.62, green: 0.91, blue: 1).opacity(0.18), location: 0),
                        .init(color: Color(red: 0.84, green: 0.66, blue: 1).opacity(0.12), location: 0.28),
                        .init(color: .clear, location: 0.72),
                    ]),
                    center: lightCenter,
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.52
                )

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.43),
                        .init(color: Color.cyan.opacity(0.10), location: 0.475),
                        .init(color: .white.opacity(0.24), location: 0.505),
                        .init(color: Color.pink.opacity(0.10), location: 0.54),
                        .init(color: .clear, location: 0.59),
                        .init(color: .clear, location: 1.00),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .scaleEffect(1.65)
                .rotationEffect(.degrees(-28 + Double(tilt.height * 18)))
                .offset(x: tilt.width * size.width * 0.62, y: tilt.height * size.height * 0.40)

                FoilMicrotexture(tilt: tilt)
                    .opacity(0.22 + response * 0.04)
            }
        }
        .allowsHitTesting(false)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.06), 0.94)
    }
}

/// Gentle light/dark falloff gives the flat photo a coated, curved response.
private struct DirectionalSurfaceLight: View, Animatable {
    var tilt: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tilt.width, tilt.height) }
        set { tilt = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.15),
                .clear,
                Color(red: 0.76, green: 0.88, blue: 1).opacity(0.075),
                .clear,
                .black.opacity(0.08),
            ],
            startPoint: UnitPoint(x: 0.08 + tilt.width * 0.08, y: 0.04 + tilt.height * 0.08),
            endPoint: UnitPoint(x: 0.92 + tilt.width * 0.08, y: 0.96 + tilt.height * 0.08)
        )
        .allowsHitTesting(false)
    }
}

/// Fine diffraction grooves and tiny facets. The pattern is deterministic and
/// only changes when the viewing angle changes, so it is free when idle.
private struct FoilMicrotexture: View, Animatable {
    var tilt: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tilt.width, tilt.height) }
        set { tilt = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let spacing: CGFloat = 8
            let phase = (tilt.width * 13 + tilt.height * 9) * spacing
            let diagonal = size.width * 0.34
            let count = Int((size.height + diagonal * 2) / spacing) + 2

            for index in -count...count {
                let y = CGFloat(index) * spacing + phase.truncatingRemainder(dividingBy: spacing)
                var path = Path()
                path.move(to: CGPoint(x: -size.width * 0.2, y: y + diagonal))
                path.addLine(to: CGPoint(x: size.width * 1.2, y: y - diagonal))
                context.stroke(
                    path,
                    with: .color(.white.opacity(index.isMultiple(of: 4) ? 0.20 : 0.075)),
                    lineWidth: index.isMultiple(of: 4) ? 0.72 : 0.34
                )
            }

            let columns = max(Int(size.width / 34), 1)
            let rows = max(Int(size.height / 34), 1)
            for row in 0...rows {
                for column in 0...columns {
                    let seed = (row * 37 + column * 19) % 11
                    let x = (CGFloat(column) + 0.34 + CGFloat(seed) * 0.027) * size.width / CGFloat(columns + 1)
                        + tilt.width * 3
                    let y = (CGFloat(row) + 0.28 + CGFloat((seed * 7) % 9) * 0.025) * size.height / CGFloat(rows + 1)
                        + tilt.height * 3
                    let radius: CGFloat = seed.isMultiple(of: 3) ? 1.15 : 0.68
                    var facet = Path()
                    facet.move(to: CGPoint(x: x, y: y - radius))
                    facet.addLine(to: CGPoint(x: x + radius, y: y))
                    facet.addLine(to: CGPoint(x: x, y: y + radius))
                    facet.addLine(to: CGPoint(x: x - radius, y: y))
                    facet.closeSubpath()
                    let color = seed.isMultiple(of: 2)
                        ? Color(red: 0.72, green: 0.94, blue: 1).opacity(0.22)
                        : Color(red: 1, green: 0.73, blue: 0.91).opacity(0.18)
                    context.fill(facet, with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Holographic Sticker – Maple Leaf") {
    HolographicStickerDetailView(sticker: BoardSticker.demo[0])
}
