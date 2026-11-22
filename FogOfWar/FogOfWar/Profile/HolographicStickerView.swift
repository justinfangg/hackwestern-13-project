import SwiftUI
import UIKit

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
    let sticker = BoardSticker.demo[0]
    HolographicStickerView(
        image: sticker.uiImage ?? UIImage(),
        identifier: sticker.id,
        maximumSize: CGSize(width: 260, height: 180),
        outlineWidth: sticker.outline,
        accessibilityLabel: sticker.accessibilityName,
        translationLimit: CGSize(width: 40, height: 20)
    )
}
