import SwiftUI

/// The profile's "Memory Board" (Figma 42:2170): a dotted, zoomable canvas of stickers.
///
/// - Pinch to zoom around your fingers; drag to pan; double-tap to fit every
///   sticker again. The board opens fitted to all stickers.
/// - Press and hold a sticker to peel it off; it lifts and tilts away from your
///   finger and follows it until you let go, when it sticks back down.
///   Positions and stacking order are saved (`StickerBoardStore`).
///
/// Stickers live in "world" space: the Figma board's coordinates (336 × 526 pt).
/// A `Camera` maps world space onto the board on screen.
struct StickerBoard: View {
    var stickers: [BoardSticker] = BoardSticker.demo
    var label: String

    /// Maps world space (Figma board points) to the board on screen.
    struct Camera: Equatable {
        /// Screen points per world point.
        var scale: CGFloat
        /// Where the world origin sits on screen.
        var offset: CGSize

        func view(_ world: CGPoint) -> CGPoint {
            CGPoint(x: world.x * scale + offset.width, y: world.y * scale + offset.height)
        }

        func world(_ view: CGPoint) -> CGPoint {
            CGPoint(x: (view.x - offset.width) / scale, y: (view.y - offset.height) / scale)
        }

        func view(_ rect: CGRect) -> CGRect {
            CGRect(origin: view(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
        }
    }

    private enum Touch: Equatable {
        case idle
        /// Finger down on a sticker, waiting out the hold before it peels.
        case pending(String)
        /// Finger moved before the hold finished: the drag pans the board instead.
        case panning(String)
        /// A pinch took over this touch; it does nothing more.
        case ignored(String)
        /// Sticker is peeled off and follows the finger.
        case lifted(String)

        var stickerID: String? {
            switch self {
            case .idle: nil
            case .pending(let id), .panning(let id), .ignored(let id), .lifted(let id): id
            }
        }
    }

    // Sticker touch
    @State private var touch: Touch = .idle
    @State private var liftTask: Task<Void, Never>?
    @State private var latestTranslation: CGSize = .zero
    @State private var liftTranslation: CGSize = .zero
    /// How far the lifted sticker has moved, in world points.
    @State private var dragOffset: CGSize = .zero
    /// Unit vector from the sticker's center toward the finger; that side peels up.
    @State private var grabDirection = CGVector(dx: 0, dy: -1)
    @State private var liftCount = 0
    @State private var dropCount = 0
    @GestureState private var isTouchingSticker = false

    // Camera
    /// `nil` keeps the board fitted to all stickers (the default view).
    @State private var camera: Camera?
    @State private var boardSize: CGSize = .zero
    @State private var panStart: Camera?
    @State private var panBaseTranslation: CGSize = .zero
    @State private var pinchStart: Camera?

    private let store = StickerBoardStore.shared

    private static let space = "stickerBoard"
    private static let cornerRadius: CGFloat = 20
    private static let borderWidth: CGFloat = 5
    private static let holdDuration: Duration = .milliseconds(220)
    /// Movement allowed during the hold before the press turns into a pan.
    private static let touchSlop: CGFloat = 10
    /// Fitted view keeps stickers clear of the month label and the border.
    private static let fitInsets = EdgeInsets(top: 44, leading: 12, bottom: 12, trailing: 12)
    /// Zoom range relative to the board at Figma scale.
    private static let maxZoom: CGFloat = 3
    private static let minZoom: CGFloat = 0.45
    /// Some sticker always stays at least this far onto the board when panning.
    private static let panMargin: CGFloat = 60
    private static let cameraSpring: Animation = .spring(duration: 0.45, bounce: 0.15)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cam = currentCamera(in: size)

            ZStack(alignment: .topLeading) {
                DotGrid(scale: cam.scale, offset: cam.offset)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                            .onChanged { pan(by: $0.translation) }
                            .onEnded { _ in endPan() }
                    )
                    .onTapGesture(count: 2) { fitAll() }

                world(camera: cam)

                monthLabel
                    .padding(.leading, 5)
                    .padding(.top, 7)
                    .allowsHitTesting(false)

                if isMovedFromFit(cam, in: size) {
                    fitButton
                        .padding(10)
                        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: isMovedFromFit(cam, in: size))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.space))
            .simultaneousGesture(magnifyGesture)
            .onAppear { boardSize = size }
            .onChange(of: size) { boardSize = size }
            .accessibilityElement(children: .contain)
            .accessibilityZoomAction { action in
                zoom(by: action.direction == .zoomIn ? 1.4 : 1 / 1.4,
                     around: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius - Self.borderWidth, style: .continuous))
        .padding(Self.borderWidth)
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(SideQuestDesign.boardBorder, lineWidth: Self.borderWidth)
        }
        // A cancelled touch (e.g. a system gesture) never reaches `onEnded`.
        .onChange(of: isTouchingSticker) { _, touching in
            if !touching, let id = touch.stickerID { finishTouch(id) }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: liftCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: dropCount)
    }

    /// Stickers laid out in world space, then scaled and moved by the camera as one layer.
    private func world(camera cam: Camera) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stickers.enumerated()), id: \.element.id) { index, sticker in
                let placement = store.placement(for: sticker, order: index)
                let isLifted = touch == .lifted(sticker.id)
                let center = worldCenter(of: placement)

                StickerArt(sticker: sticker)
                    .rotationEffect(.degrees(sticker.rotation))
                    .modifier(PeelEffect(isLifted: isLifted, direction: grabDirection))
                    .gesture(stickerGesture(for: sticker, viewCenter: cam.view(center)))
                    .accessibilityElement()
                    .accessibilityLabel("\(sticker.accessibilityName) sticker")
                    .position(
                        x: center.x + (isLifted ? dragOffset.width : 0),
                        y: center.y + (isLifted ? dragOffset.height : 0)
                    )
                    .zIndex(Double(placement.z) + (isLifted ? 10_000 : 0))
            }
        }
        .frame(
            width: BoardSticker.designBoardSize.width,
            height: BoardSticker.designBoardSize.height,
            alignment: .topLeading
        )
        .scaleEffect(cam.scale, anchor: .topLeading)
        .offset(cam.offset)
    }

    private var monthLabel: some View {
        Text(label)
            .font(SideQuestDesign.ptSans(fixed: 17))
            .tracking(-0.51)
            .foregroundStyle(SideQuestDesign.boardLabelText)
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(.white, in: Capsule())
    }

    /// Zooms back out to show every sticker (double-tapping the board does the same).
    private var fitButton: some View {
        Button(action: fitAll) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SideQuestDesign.boardLabelText)
                .frame(width: 36, height: 36)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show all stickers")
    }

    // MARK: Camera

    /// The player has zoomed or panned away from the fitted view.
    private func isMovedFromFit(_ cam: Camera, in size: CGSize) -> Bool {
        guard camera != nil else { return false }
        let fit = fittedCamera(in: size)
        return abs(cam.scale - fit.scale) > 0.01
            || abs(cam.offset.width - fit.offset.width) > 2
            || abs(cam.offset.height - fit.offset.height) > 2
    }

    private func currentCamera(in size: CGSize) -> Camera {
        camera ?? fittedCamera(in: size)
    }

    /// Zoom (screen points per world point) of the board at Figma scale.
    private func baseScale(in size: CGSize) -> CGFloat {
        max(size.width / BoardSticker.designBoardSize.width, 0.01)
    }

    /// Bounding box of every sticker's visible artwork (outline included), in world space.
    private var contentBounds: CGRect {
        let boxes = stickers.enumerated().map { index, sticker in
            StickerGeometry.visibleBounds(
                of: sticker,
                at: worldCenter(of: store.placement(for: sticker, order: index))
            )
        }
        guard let first = boxes.first else { return CGRect(origin: .zero, size: BoardSticker.designBoardSize) }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Camera that shows every sticker, centered, without zooming past Figma scale.
    private func fittedCamera(in size: CGSize) -> Camera {
        let bounds = contentBounds
        let insets = Self.fitInsets
        let available = CGSize(
            width: max(size.width - insets.leading - insets.trailing, 1),
            height: max(size.height - insets.top - insets.bottom, 1)
        )
        let scale = min(
            available.width / max(bounds.width, 1),
            available.height / max(bounds.height, 1),
            baseScale(in: size)
        )
        let offset = CGSize(
            width: insets.leading + (available.width - bounds.width * scale) / 2 - bounds.minX * scale,
            height: insets.top + (available.height - bounds.height * scale) / 2 - bounds.minY * scale
        )
        return Camera(scale: scale, offset: offset)
    }

    private func scaleRange(in size: CGSize) -> ClosedRange<CGFloat> {
        let base = baseScale(in: size)
        let lower = min(fittedCamera(in: size).scale, base * Self.minZoom)
        return lower...(base * Self.maxZoom)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if case .lifted = touch { return }
                if pinchStart == nil {
                    pinchStart = currentCamera(in: boardSize)
                    panStart = nil
                    // The pinch owns the touch now: no peel, no pan.
                    if let id = touch.stickerID {
                        liftTask?.cancel()
                        touch = .ignored(id)
                    }
                }
                guard let start = pinchStart else { return }
                let range = scaleRange(in: boardSize)
                let scale = min(max(start.scale * value.magnification, range.lowerBound), range.upperBound)
                camera = Self.camera(start, zoomedTo: scale, around: value.startLocation)
            }
            .onEnded { _ in
                pinchStart = nil
                settleCamera()
            }
    }

    /// `start` rescaled so the world point under `anchor` stays put.
    private static func camera(_ start: Camera, zoomedTo scale: CGFloat, around anchor: CGPoint) -> Camera {
        let ratio = scale / start.scale
        return Camera(
            scale: scale,
            offset: CGSize(
                width: anchor.x - (anchor.x - start.offset.width) * ratio,
                height: anchor.y - (anchor.y - start.offset.height) * ratio
            )
        )
    }

    private func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let start = currentCamera(in: boardSize)
        let range = scaleRange(in: boardSize)
        let scale = min(max(start.scale * factor, range.lowerBound), range.upperBound)
        withAnimation(Self.cameraSpring) {
            camera = clamped(Self.camera(start, zoomedTo: scale, around: anchor))
        }
    }

    private func pan(by translation: CGSize) {
        guard pinchStart == nil else {
            panStart = nil
            return
        }
        if panStart == nil {
            panStart = currentCamera(in: boardSize)
            panBaseTranslation = translation
        }
        guard let start = panStart else { return }
        camera = Camera(
            scale: start.scale,
            offset: CGSize(
                width: start.offset.width + translation.width - panBaseTranslation.width,
                height: start.offset.height + translation.height - panBaseTranslation.height
            )
        )
    }

    private func endPan() {
        panStart = nil
        settleCamera()
    }

    private func fitAll() {
        withAnimation(Self.cameraSpring) { camera = nil }
    }

    /// Springs back if the stickers were panned (almost) out of view.
    private func settleCamera() {
        guard let camera else { return }
        let target = clamped(camera)
        guard target != camera else { return }
        withAnimation(Self.cameraSpring) { self.camera = target }
    }

    private func clamped(_ cam: Camera) -> Camera {
        let rect = cam.view(contentBounds)
        let margin = min(Self.panMargin, boardSize.width / 2, boardSize.height / 2)
        var offset = cam.offset
        if rect.maxX < margin { offset.width += margin - rect.maxX }
        if rect.minX > boardSize.width - margin { offset.width -= rect.minX - (boardSize.width - margin) }
        if rect.maxY < margin { offset.height += margin - rect.maxY }
        if rect.minY > boardSize.height - margin { offset.height -= rect.minY - (boardSize.height - margin) }
        return Camera(scale: cam.scale, offset: offset)
    }

    // MARK: Sticker gesture

    private func worldCenter(of placement: StickerBoardStore.Placement) -> CGPoint {
        CGPoint(
            x: placement.x * BoardSticker.designBoardSize.width,
            y: placement.y * BoardSticker.designBoardSize.height
        )
    }

    private func stickerGesture(for sticker: BoardSticker, viewCenter: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($isTouchingSticker) { _, state, _ in state = true }
            .onChanged { value in
                latestTranslation = value.translation
                switch touch {
                case .idle:
                    guard pinchStart == nil else { return }
                    touch = .pending(sticker.id)
                    grabDirection = Self.direction(from: viewCenter, to: value.startLocation)
                    liftTask?.cancel()
                    liftTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.holdDuration)
                        guard !Task.isCancelled, touch == .pending(sticker.id) else { return }
                        lift(sticker)
                    }
                case .pending(sticker.id):
                    if hypot(value.translation.width, value.translation.height) > Self.touchSlop {
                        liftTask?.cancel()
                        touch = .panning(sticker.id)
                        pan(by: value.translation)
                    }
                case .panning(sticker.id):
                    pan(by: value.translation)
                case .lifted(sticker.id):
                    let scale = currentCamera(in: boardSize).scale
                    dragOffset = CGSize(
                        width: (value.translation.width - liftTranslation.width) / scale,
                        height: (value.translation.height - liftTranslation.height) / scale
                    )
                default:
                    break
                }
            }
            .onEnded { _ in finishTouch(sticker.id) }
    }

    private func lift(_ sticker: BoardSticker) {
        // Freeze the view so the fitted camera can't shift while the sticker moves.
        if camera == nil { camera = fittedCamera(in: boardSize) }
        store.bringToFront(sticker, among: stickers)
        liftTranslation = latestTranslation
        dragOffset = .zero
        withAnimation(.spring(duration: 0.32, bounce: 0.4)) {
            touch = .lifted(sticker.id)
        }
        liftCount += 1
    }

    private func finishTouch(_ id: String) {
        guard touch.stickerID == id else { return }
        liftTask?.cancel()
        liftTask = nil

        if touch == .panning(id) { endPan() }

        guard touch == .lifted(id),
              let index = stickers.firstIndex(where: { $0.id == id }),
              boardSize.width > 0, boardSize.height > 0 else {
            touch = .idle
            return
        }

        // Stick it down where it was dropped, kept within the visible board.
        let sticker = stickers[index]
        let cam = currentCamera(in: boardSize)
        let center = worldCenter(of: store.placement(for: sticker, order: index))
        let inset = 16 / cam.scale
        let visibleMin = cam.world(.zero)
        let visibleMax = cam.world(CGPoint(x: boardSize.width, y: boardSize.height))
        let x = min(max(center.x + dragOffset.width, visibleMin.x + inset), visibleMax.x - inset)
        let y = min(max(center.y + dragOffset.height, visibleMin.y + inset), visibleMax.y - inset)

        withAnimation(.spring(duration: 0.42, bounce: 0.32)) {
            store.move(
                sticker,
                to: CGPoint(
                    x: x / BoardSticker.designBoardSize.width,
                    y: y / BoardSticker.designBoardSize.height
                ),
                among: stickers
            )
            dragOffset = .zero
            touch = .idle
        }
        dropCount += 1
    }

    /// Unit vector from `center` toward `point`; grabbing near the middle peels the top edge.
    private static func direction(from center: CGPoint, to point: CGPoint) -> CGVector {
        let dx = point.x - center.x, dy = point.y - center.y
        let length = hypot(dx, dy)
        guard length > 12 else { return CGVector(dx: 0, dy: -1) }
        return CGVector(dx: dx / length, dy: dy / length)
    }
}

/// Where a sticker's artwork is actually visible, so "fit all" hugs the art
/// rather than each image's transparent padding.
@MainActor
private enum StickerGeometry {
    private static var opaqueRects: [String: CGRect] = [:]

    /// World-space bounding box of the sticker's opaque pixels plus outline,
    /// rotated and centered at `center`.
    static func visibleBounds(of sticker: BoardSticker, at center: CGPoint) -> CGRect {
        let size = sticker.size
        let unit = opaqueUnitRect(of: sticker.imageName)
        // Opaque area inside the sticker's frame, relative to the frame's center.
        let art = CGRect(
            x: (sticker.imageRect.minX + unit.minX * sticker.imageRect.width) * size.width - size.width / 2,
            y: (sticker.imageRect.minY + unit.minY * sticker.imageRect.height) * size.height - size.height / 2,
            width: unit.width * sticker.imageRect.width * size.width,
            height: unit.height * sticker.imageRect.height * size.height
        ).insetBy(dx: -sticker.outline, dy: -sticker.outline)

        let angle = sticker.rotation * .pi / 180
        let (cosA, sinA) = (cos(angle), sin(angle))
        let corners = [
            CGPoint(x: art.minX, y: art.minY), CGPoint(x: art.maxX, y: art.minY),
            CGPoint(x: art.minX, y: art.maxY), CGPoint(x: art.maxX, y: art.maxY),
        ].map { CGPoint(x: center.x + $0.x * cosA - $0.y * sinA, y: center.y + $0.x * sinA + $0.y * cosA) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Opaque region of an image as fractions of its size (whole image if unknown).
    private static func opaqueUnitRect(of imageName: String) -> CGRect {
        if let cached = opaqueRects[imageName] { return cached }
        let rect = measureOpaqueRect(of: imageName) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        opaqueRects[imageName] = rect
        return rect
    }

    /// Scans a small alpha-only copy of the image; plenty for fitting.
    private static func measureOpaqueRect(of imageName: String) -> CGRect? {
        guard let cgImage = UIImage(named: imageName)?.cgImage else { return nil }
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        let factor = min(1, 128 / longest)
        let width = max(Int(CGFloat(cgImage.width) * factor), 1)
        let height = max(Int(CGFloat(cgImage.height) * factor), 1)
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where alpha[row * width + column] > 24 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Bitmap memory is stored top row first, matching the image's orientation.
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }
}

/// Lifts a sticker off the board: it grows, casts a deeper shadow and tilts
/// so the side under the finger rises toward the viewer, like a sticker being
/// peeled up from that edge.
private struct PeelEffect: ViewModifier {
    var isLifted: Bool
    var direction: CGVector

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(isLifted ? 20 : 0),
                axis: (x: direction.dy, y: -direction.dx, z: 0),
                anchor: UnitPoint(x: 0.5 - direction.dx * 0.5, y: 0.5 - direction.dy * 0.5),
                perspective: 0.5
            )
            .scaleEffect(isLifted ? 1.08 : 1)
            .shadow(
                color: .black.opacity(isLifted ? 0.3 : 0),
                radius: isLifted ? 16 : 0,
                x: 0,
                y: isLifted ? 18 : 0
            )
    }
}

/// One sticker at world size: artwork plus its white cutout outline and Figma drop shadow.
private struct StickerArt: View {
    let sticker: BoardSticker

    @Environment(\.displayScale) private var displayScale
    @State private var outlined: UIImage?

    /// Rendered sharper than the screen so zooming in stays crisp.
    private static let zoomHeadroom: CGFloat = 2.5
    private static let maxPixelSide: CGFloat = 2400

    var body: some View {
        let canvas = sticker.size
        let pad = StickerOutline.padding(for: sticker.outline)

        ZStack {
            if let outlined {
                Image(uiImage: outlined)
                    .resizable()
                    .transition(.opacity)
            } else {
                // Shown for the moment it takes to render the outline.
                Image(sticker.imageName)
                    .resizable()
                    .frame(width: sticker.imageRect.width * canvas.width, height: sticker.imageRect.height * canvas.height)
                    .position(
                        x: pad + sticker.imageRect.midX * canvas.width,
                        y: pad + sticker.imageRect.midY * canvas.height
                    )
            }
        }
        .frame(width: canvas.width + pad * 2, height: canvas.height + pad * 2)
        .shadow(
            color: .black.opacity(sticker.shadow?.opacity ?? 0),
            radius: sticker.shadow?.radius ?? 0,
            x: 0,
            y: sticker.shadow?.y ?? 0
        )
        .task(id: displayScale) {
            let sticker = sticker
            let longestSide = max(canvas.width, canvas.height) + pad * 2
            let renderScale = min(displayScale * Self.zoomHeadroom, Self.maxPixelSide / longestSide)
            let rect = CGRect(
                x: sticker.imageRect.minX * canvas.width,
                y: sticker.imageRect.minY * canvas.height,
                width: sticker.imageRect.width * canvas.width,
                height: sticker.imageRect.height * canvas.height
            )
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let art = UIImage(named: sticker.imageName) else { return nil }
                return StickerOutline.render(
                    art,
                    cacheKey: sticker.id,
                    canvas: canvas,
                    imageRect: rect,
                    thickness: sticker.outline,
                    scale: renderScale
                )
            }.value
            withAnimation(.easeOut(duration: 0.15)) { outlined = image }
        }
    }
}

/// Figma board background: light dots on a ~10.7 pt grid that zooms and pans
/// with the stickers (thinned out when zoomed far out).
private struct DotGrid: View, Animatable {
    var scale: CGFloat
    var offset: CGSize

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(scale, AnimatablePair(offset.width, offset.height)) }
        set {
            scale = newValue.first
            offset = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    private static let spacing: CGFloat = 10.7
    private static let diameter: CGFloat = 3.2

    var body: some View {
        Canvas { context, size in
            var spacing = Self.spacing * scale
            while spacing < 7 { spacing *= 2 }
            let diameter = min(max(Self.diameter * scale, 1.6), 5)
            let startX = offset.width.truncatingRemainder(dividingBy: spacing) - spacing
            let startY = offset.height.truncatingRemainder(dividingBy: spacing) - spacing

            var dots = Path()
            for y in stride(from: startY, through: size.height + spacing, by: spacing) {
                for x in stride(from: startX, through: size.width + spacing, by: spacing) {
                    dots.addEllipse(in: CGRect(
                        x: x - diameter / 2,
                        y: y - diameter / 2,
                        width: diameter,
                        height: diameter
                    ))
                }
            }
            context.fill(dots, with: .color(SideQuestDesign.boardDot))
        }
        .accessibilityHidden(true)
    }
}
