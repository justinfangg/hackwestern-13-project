import CoreImage
import SwiftUI
import UIKit
import FogKit

/// A photo taken for the active quest, shown on the card while it's checked.
struct QuestPhoto: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// Result face of the active-quest card. Takes over from the camera the moment
/// the shutter fires:
///
/// 1. The photo shrinks into the middle of the card and shimmers bottom to top
///    while Gemini checks it.
/// 2. The card grows to (almost) the top of the screen with the answer.
///    - Wrong object: the photo greys out and rises, "Wrong object" and the
///      tries left sit under it, "Try again" at the bottom.
///    - Found: the object peels off the photo like a sticker, the rest of the
///      photo crumbles into particles, then "{Object} found!" and "Complete quest".
/// 3. "Complete quest" opens the sticker stats inside the card; the sticker flies
///    to its spot at the top, as it does from the profile's memory board.
struct QuestResultView: View {
    let photo: CGImage
    let quest: Quest
    let capture: QuestCaptureModel
    /// The card is at its tallest (it grows once the answer is in).
    @Binding var isExpanded: Bool
    /// Runs the verification; the answer is read from `capture.state` afterwards.
    let submit: () async -> Void
    /// Distance, time and route so far, for the sticker stats.
    let expedition: () -> ExpeditionSummary?
    let onRetry: () -> Void
    let onClose: () -> Void
    /// The sticker stats were closed: the quest is done.
    let onFinish: () -> Void
    /// "Done" on the sticker stats: the quest is done and the sticker goes onto the profile board.
    let onDone: () -> Void
    /// The photo's subject already cut out, in place (Demo mode's bundled flower). Used instead of
    /// on-device subject lifting, which can't run in the iOS Simulator.
    var presetCutout: SubjectCutout? = nil

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var staged: StagedPhoto?
    @State private var prepared: PreparedSubject?
    @State private var phase: Phase = .verifying
    @State private var isShrunk = false
    @State private var peel: Peel = .flat
    /// When the photo started crumbling (`nil` before and after).
    @State private var dissolveStart: Date?
    @State private var isPhotoGone = false
    @State private var isStickerCentered = false
    @State private var showsFoundText = false
    @State private var stats: Stats?
    @State private var isStatsShown = false

    enum Phase: Equatable {
        case verifying
        case failed(Failure)
        case found
    }

    struct Failure: Equatable {
        enum Action { case retry, close }
        var title: String
        var detail: String
        var action: Action
    }

    /// Steps of the sticker coming off the photo.
    private enum Peel: Int, Comparable {
        /// Still part of the photo.
        case flat
        /// A white die-cut line appears around the object.
        case outlined
        /// Its bottom edge curls up toward the viewer.
        case peeling
        /// Off the photo, floating above it.
        case lifted

        static func < (a: Peel, b: Peel) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Stats {
        let sticker: BoardSticker
        let source: StickerPlacement
        let expedition: ExpeditionSummary?
        let date: Date
    }

    // MARK: Layout

    /// The shrunk photo: at most this share of the card's width, and this tall.
    private static let photoWidthFraction: CGFloat = 0.64
    private static let photoMaxHeight: CGFloat = 340
    private static let photoCornerRadius: CGFloat = 26
    /// How much bigger the sticker gets once it's off the photo.
    private static let liftScale: CGFloat = 1.1
    private static let liftRise: CGFloat = 14
    /// White die-cut border around the sticker (pt).
    private static let outlineWidth: CGFloat = 6
    /// Same as the card's corner radius minus the inset, so the button is concentric with it.
    private static let buttonInset: CGFloat = 24
    private static let buttonHeight: CGFloat = 58
    /// Shimmer at least this long, so a quick answer still reads as "checked".
    private static let minimumCheckDuration: TimeInterval = 1.6

    private static let shrink: Animation = .spring(duration: 0.55, bounce: 0.12)
    private static let grow: Animation = .spring(duration: 0.6, bounce: 0.14)
    private static let statsAnimation: Animation = .spring(duration: 0.55, bounce: 0.16)
    private static let fadeBlur: CGFloat = 14

    private var aspect: CGFloat {
        let size = staged?.photo.size ?? CGSize(width: photo.width, height: photo.height)
        return size.height > 0 ? size.width / size.height : 1
    }

    private func photoFrame(in size: CGSize) -> CGRect {
        guard isShrunk else { return CGRect(origin: .zero, size: size) }
        var width = size.width * Self.photoWidthFraction
        var height = width / aspect
        if height > Self.photoMaxHeight {
            height = Self.photoMaxHeight
            width = height * aspect
        }
        let centerY: CGFloat
        switch phase {
        case .verifying: centerY = size.height / 2
        // Above the middle, leaving room for the text under it.
        case .failed: centerY = size.height * 0.4
        case .found: centerY = size.height * 0.42
        }
        return CGRect(x: (size.width - width) / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// The object's box in the card, from where it sits in the photo.
    private func subjectRect(in frame: CGRect) -> CGRect? {
        guard let bounds = prepared?.bounds else { return nil }
        return CGRect(
            x: frame.minX + bounds.minX * frame.width,
            y: frame.minY + bounds.minY * frame.height,
            width: bounds.width * frame.width,
            height: bounds.height * frame.height
        )
    }

    private func stickerCenter(subject: CGRect, in size: CGSize) -> CGPoint {
        if isStickerCentered { return CGPoint(x: size.width / 2, y: size.height * 0.42) }
        let rise = peel == .lifted ? Self.liftRise : 0
        return CGPoint(x: subject.midX, y: subject.midY - rise)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var objectName: String {
        let name = QuestCategory.displayName(quest.category)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = photoFrame(in: size)

            ZStack(alignment: .topLeading) {
                // The stats page is light, like the profile sheet.
                SideQuestDesign.profileSurface
                    .opacity(isStatsShown ? 1 : 0)

                Group {
                    photoLayer(frame: frame)
                    dissolveLayer(frame: frame)
                    stickerLayer(frame: frame, size: size)
                    caption(frame: frame, size: size)
                }
                .opacity(isStatsShown ? 0 : 1)
                .blur(radius: isStatsShown ? Self.fadeBlur : 0)
                .allowsHitTesting(stats == nil)

                bottomButton
                    .opacity(isStatsShown ? 0 : 1)
                    .blur(radius: isStatsShown ? Self.fadeBlur : 0)
                    .allowsHitTesting(stats == nil)

                if let stats {
                    statsLayer(stats, width: size.width)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { currentSize = $0 }
        .task { await run() }
        .sensoryFeedback(trigger: phase) { _, new in
            switch new {
            case .found: .success
            case .failed: .error
            case .verifying: nil
            }
        }
    }

    // MARK: Photo

    private func photoLayer(frame: CGRect) -> some View {
        let showsBacking = peel >= .peeling
        let image = showsBacking ? prepared?.backing : nil

        return Image(uiImage: image ?? staged?.photo ?? UIImage(cgImage: photo))
            .resizable()
            .scaledToFill()
            .frame(width: frame.width, height: frame.height)
            .overlay {
                if phase == .verifying && isShrunk && !reduceMotion {
                    ShimmerSweep()
                        .transition(.opacity)
                }
            }
            .brightness(phase == .verifying && isShrunk ? -0.06 : 0)
            // "A little grey" after a miss.
            .saturation(isFailed ? 0.12 : 1)
            .overlay(Color(white: 0.55).opacity(isFailed ? 0.22 : 0))
            .clipShape(RoundedRectangle(
                cornerRadius: isShrunk ? Self.photoCornerRadius : ActiveQuestCard.cornerRadius,
                style: .continuous
            ))
            .opacity(isPhotoGone ? 0 : 1)
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel("Your photo")
            .accessibilityValue(phase == .verifying ? "Checking" : "")
    }

    @ViewBuilder
    private func dissolveLayer(frame: CGRect) -> some View {
        if let start = dissolveStart, let prepared {
            ParticleDissolve(
                image: prepared.backing,
                particles: prepared.particles,
                columns: prepared.columns,
                rows: prepared.rows,
                origin: start,
                cornerRadius: Self.photoCornerRadius
            )
            .frame(width: frame.width + ParticleDissolve.margin * 2,
                   height: frame.height + ParticleDissolve.margin * 2)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Sticker

    @ViewBuilder
    private func stickerLayer(frame: CGRect, size: CGSize) -> some View {
        if let prepared, let subject = subjectRect(in: frame), stats == nil,
           let outlined = StickerOutline.render(
               prepared.subject,
               cacheKey: prepared.id,
               canvas: subject.size,
               imageRect: CGRect(origin: .zero, size: subject.size),
               thickness: Self.outlineWidth,
               scale: displayScale
           ) {
            let pad = StickerOutline.padding(for: Self.outlineWidth)
            let outer = CGSize(width: subject.width + pad * 2, height: subject.height + pad * 2)

            Image(uiImage: outlined)
                .resizable()
                .frame(width: outer.width, height: outer.height)
                // Light catching the curled-up edge.
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)],
                                   startPoint: .bottom, endPoint: .center)
                        .mask(Image(uiImage: outlined).resizable())
                        .opacity(peel == .peeling ? 1 : 0)
                }
                .rotation3DEffect(
                    .degrees(peel == .peeling ? 38 : 0),
                    axis: (x: 1, y: 0, z: 0),
                    anchor: .top,
                    perspective: 0.6
                )
                .scaleEffect(peel == .lifted ? Self.liftScale : (peel == .peeling ? 1.03 : 1))
                .shadow(
                    color: .black.opacity(peel == .lifted ? 0.31 : (peel == .peeling ? 0.18 : 0)),
                    radius: peel == .lifted ? 20 : 6,
                    y: peel == .lifted ? 8 : 3
                )
                .opacity(peel == .flat ? 0 : 1)
                .position(stickerCenter(subject: subject, in: size))
                .accessibilityLabel("\(objectName) sticker")
                .accessibilityHidden(peel == .flat)
        }
    }

    // MARK: Text and buttons

    @ViewBuilder
    private func caption(frame: CGRect, size: CGSize) -> some View {
        switch phase {
        case .verifying:
            EmptyView()
        case .failed(let failure):
            VStack(spacing: 6) {
                Text(failure.title)
                    .font(SideQuestDesign.calSans(32, relativeTo: .title))
                    .tracking(-0.32)
                Text(failure.detail)
                    .font(SideQuestDesign.ptSans(20))
                    .tracking(-0.6)
                    .opacity(0.6)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(SideQuestDesign.pillText)
            .padding(.horizontal, 32)
            .frame(width: size.width)
            .fixedSize(horizontal: false, vertical: true)
            .position(x: size.width / 2, y: frame.maxY + 56)
            .transition(.opacity.combined(with: .offset(y: 14)).animation(.spring(duration: 0.5).delay(0.15)))
            .accessibilityElement(children: .combine)
        case .found:
            if showsFoundText {
                Text("\(objectName) found!")
                    .font(SideQuestDesign.calSans(34, relativeTo: .title))
                    .tracking(-0.34)
                    .foregroundStyle(SideQuestDesign.pillText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 32)
                    .frame(width: size.width)
                    .position(x: size.width / 2,
                              y: size.height - Self.buttonInset - Self.buttonHeight - 44)
                    .transition(.opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.92)))
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private var bottomButton: some View {
        VStack {
            Spacer(minLength: 0)
            switch phase {
            case .verifying:
                EmptyView()
            case .failed(let failure):
                Group {
                    switch failure.action {
                    case .retry:
                        pillButton("Try again", fill: .white, text: SideQuestDesign.primaryText, action: onRetry)
                    case .close:
                        pillButton("Close", fill: .white, text: SideQuestDesign.primaryText, action: onClose)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 24)).animation(.spring(duration: 0.5).delay(0.2)))
            case .found:
                if showsFoundText {
                    pillButton("Complete quest", fill: SideQuestDesign.accentGreen, text: .white, action: completeQuest)
                        .transition(.opacity.combined(with: .offset(y: 24)).animation(.spring(duration: 0.5).delay(0.08)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pillButton(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(SideQuestDesign.ptSans(fixed: 20))
                .tracking(-0.6)
                .foregroundStyle(text)
                .frame(maxWidth: .infinity)
                .frame(height: Self.buttonHeight)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(ResultButtonStyle())
        .padding(.horizontal, Self.buttonInset)
        .padding(.bottom, Self.buttonInset)
    }

    // MARK: Sticker stats

    @ViewBuilder
    private func statsLayer(_ stats: Stats, width: CGFloat) -> some View {
        let rest = StickerStatsLayout.heroPlacement(for: stats.sticker, width: width)

        StickerStatsView(
            sticker: stats.sticker,
            expedition: stats.expedition,
            date: stats.date,
            onDismiss: onFinish,
            footerInset: Self.buttonInset + Self.buttonHeight
        )
        .opacity(isStatsShown ? 1 : 0)
        .blur(radius: isStatsShown ? 0 : Self.fadeBlur)
        .allowsHitTesting(isStatsShown)
        .onAppear {
            guard !isStatsShown else { return }
            withAnimation(Self.statsAnimation) { isStatsShown = true }
        }

        StickerHeroView(
            sticker: stats.sticker,
            placement: isStatsShown ? rest : stats.source,
            restScale: rest.scale,
            movement: CGSize(
                width: max(0, min(48, (width - stats.sticker.size.width * rest.scale) / 2 - 16)),
                height: 14
            )
        )
        .allowsHitTesting(isStatsShown)

        VStack {
            Spacer(minLength: 0)
            pillButton("Done", fill: SideQuestDesign.canvas, text: .white, action: onDone)
                .accessibilityHint("Adds the sticker to your profile board")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isStatsShown ? 1 : 0)
        .offset(y: isStatsShown ? 0 : 24)
        .allowsHitTesting(isStatsShown)
    }

    private func completeQuest() {
        guard stats == nil else { return }
        // Same geometry the body used to draw the floating sticker.
        let size = currentSize
        guard let prepared, let fileURL = prepared.fileURL,
              let subject = subjectRect(in: photoFrame(in: size)) else {
            // No sticker art to show: the quest is still complete.
            onFinish()
            return
        }

        let sticker = BoardSticker(
            id: "quest-result.\(prepared.id)",
            imageName: "",
            size: subject.size,
            imageRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            rotation: 0,
            outline: Self.outlineWidth,
            shadow: nil,
            defaultCenter: .zero,
            accessibilityName: objectName,
            fileURL: fileURL
        )
        var date = Date.now
        if case .success(let collected) = capture.state { date = collected.collectedAt }
        stats = Stats(
            sticker: sticker,
            source: StickerPlacement(center: stickerCenter(subject: subject, in: size), scale: Self.liftScale),
            expedition: expedition(),
            date: date
        )
    }

    /// The card's size; kept from the last layout so actions can rebuild geometry.
    @State private var currentSize: CGSize = .zero

    // MARK: Sequence

    private func run() async {
        let staged = await StagedPhoto.make(from: photo, presetCutout: presetCutout)
        self.staged = staged
        try? await Task.sleep(for: .milliseconds(40))
        withAnimation(Self.shrink) { isShrunk = true }
        let started = Date.now

        // The cut-out runs alongside the verification.
        async let subject = PreparedSubject.make(from: staged)
        await submit()
        let elapsed = Date.now.timeIntervalSince(started)
        if elapsed < Self.minimumCheckDuration {
            try? await Task.sleep(for: .seconds(Self.minimumCheckDuration - elapsed))
        }
        prepared = await subject

        switch capture.state {
        case .success:
            await playFound()
        case .rejected(_, let left):
            fail(Failure(title: "Wrong object", detail: left == 1 ? "1 try left" : "\(left) tries left", action: .retry))
        case .outOfAttempts:
            fail(Failure(title: "Wrong object", detail: "No tries left today", action: .close))
        case .tooFar:
            fail(Failure(title: "Too far away", detail: "Get a little closer and try again", action: .retry))
        case .alreadyCompleted:
            fail(Failure(title: "Already found", detail: "You've finished today's quest", action: .close))
        case .error(let message):
            fail(Failure(title: "Couldn't check", detail: message, action: .retry))
        default:
            fail(Failure(title: "Couldn't check", detail: "Something went wrong. Try again.", action: .retry))
        }
    }

    private func fail(_ failure: Failure) {
        withAnimation(Self.grow) {
            phase = .failed(failure)
            isExpanded = true
        }
    }

    private func playFound() async {
        withAnimation(Self.grow) {
            phase = .found
            isExpanded = true
        }
        guard prepared != nil else {
            withAnimation(.spring(duration: 0.5)) { showsFoundText = true }
            return
        }
        try? await Task.sleep(for: .milliseconds(450))

        withAnimation(.easeOut(duration: 0.25)) { peel = .outlined }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.easeIn(duration: 0.22)) { peel = .peeling }
        try? await Task.sleep(for: .milliseconds(220))
        withAnimation(.spring(duration: 0.55, bounce: 0.32)) { peel = .lifted }
        try? await Task.sleep(for: .milliseconds(220))

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.4)) { isPhotoGone = true }
            try? await Task.sleep(for: .milliseconds(400))
        } else {
            dissolveStart = .now
            isPhotoGone = true
            try? await Task.sleep(for: .seconds(1.25))
        }

        withAnimation(.spring(duration: 0.6, bounce: 0.2)) { isStickerCentered = true }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) { showsFoundText = true }

        try? await Task.sleep(for: .seconds(ParticleDissolve.duration))
        dissolveStart = nil
    }
}

private struct ResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

// MARK: - Shimmer

/// A soft band of light sweeping up the photo, over and over.
private struct ShimmerSweep: View {
    private static let period: TimeInterval = 1.4

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let progress = CGFloat(t.truncatingRemainder(dividingBy: Self.period) / Self.period)
            GeometryReader { proxy in
                let band = proxy.size.height * 0.6
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.42), location: 0.5),
                        .init(color: .white.opacity(0), location: 1),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: proxy.size.width, height: band)
                // From just below the bottom edge to just above the top.
                .offset(y: proxy.size.height - progress * (proxy.size.height + band))
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - Photo preparation

/// The photo as shown on the card. A pre-cut sticker (the debug camera bypass)
/// is staged on a blurred copy of itself so it reads as a photo.
nonisolated struct StagedPhoto: @unchecked Sendable {
    let photo: UIImage
    let cgImage: CGImage
    /// Set when the photo was a pre-cut sticker: the object, in place in `cgImage`.
    let presetCutout: SubjectCutout?

    static func make(from source: CGImage, presetCutout: SubjectCutout? = nil) async -> StagedPhoto {
        await Task.detached(priority: .userInitiated) {
            let base = ImageEncoding.downscaled(source, maxDimension: 1024)
            if let presetCutout {
                return StagedPhoto(photo: UIImage(cgImage: base), cgImage: base, presetCutout: presetCutout)
            }
            guard VisionStickerExtractor.hasTransparentBackground(base),
                  let staged = stage(base) else {
                return StagedPhoto(photo: UIImage(cgImage: base), cgImage: base, presetCutout: nil)
            }
            return staged
        }.value
    }

    /// Puts a cut-out on a 3:4 "photo": a blurred, enlarged copy of itself behind it.
    private static func stage(_ sticker: CGImage) -> StagedPhoto? {
        let canvas = CGSize(width: 768, height: 1024)
        let fit = min(canvas.width * 0.72 / CGFloat(sticker.width), canvas.height * 0.6 / CGFloat(sticker.height))
        let size = CGSize(width: CGFloat(sticker.width) * fit, height: CGFloat(sticker.height) * fit)
        let rect = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                          width: size.width, height: size.height)

        let ci = CIImage(cgImage: sticker)
        let cover = max(canvas.width / ci.extent.width, canvas.height / ci.extent.height) * 1.5
        let backdrop = ci
            .transformed(by: CGAffineTransform(scaleX: cover, y: cover))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 60])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2, kCIInputBrightnessKey: -0.05])
        let scaled = ci.extent.size
        let backdropRect = CGRect(
            x: (scaled.width * cover - canvas.width) / 2,
            y: (scaled.height * cover - canvas.height) / 2,
            width: canvas.width,
            height: canvas.height
        )
        let context = CIContext()
        guard let backdropImage = context.createCGImage(backdrop, from: backdropRect),
              let scene = drawing(canvas, opaque: true, { ctx in
                  ctx.setFillColor(gray: 0.6, alpha: 1)
                  ctx.fill(CGRect(origin: .zero, size: canvas))
                  ctx.draw(backdropImage, in: CGRect(origin: .zero, size: canvas))
                  ctx.draw(sticker, in: rect)
              }),
              let placed = drawing(canvas, opaque: false, { ctx in ctx.draw(sticker, in: rect) })
        else { return nil }
        // Bitmap y runs up; the cut-out's bounds are measured top-down.
        let bounds = VisionStickerExtractor.opaqueBounds(of: placed)
            ?? CGRect(x: rect.minX / canvas.width, y: 1 - rect.maxY / canvas.height,
                      width: rect.width / canvas.width, height: rect.height / canvas.height)
        return StagedPhoto(photo: UIImage(cgImage: scene), cgImage: scene,
                           presetCutout: SubjectCutout(image: placed, bounds: bounds))
    }

    static func drawing(_ size: CGSize, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }
}

/// Everything the "found" animation needs: the object cut out of the photo, the
/// photo with a blank where the object was, and the particles it crumbles into.
nonisolated struct PreparedSubject: @unchecked Sendable {
    let id: String
    /// The object alone, cropped to `bounds`.
    let subject: UIImage
    /// Where the object sits in the photo, as fractions of it (origin top-left).
    let bounds: CGRect
    /// The photo with the sticker's backing paper showing where the object was.
    let backing: UIImage
    let particles: [DissolveParticle]
    let columns: Int
    let rows: Int
    /// The sticker art on disk, for `BoardSticker` (the stats page reads it from there).
    let fileURL: URL?

    /// Sticker backing paper left behind when the object peels off.
    private static let backingGray: CGFloat = 0.93
    private static let columns = 38

    static func make(from staged: StagedPhoto) async -> PreparedSubject? {
        let cutout: SubjectCutout
        if let preset = staged.presetCutout {
            cutout = preset
        } else {
            cutout = await VisionStickerExtractor.cutoutInPlace(from: staged.cgImage)
        }
        return await Task.detached(priority: .userInitiated) {
            build(photo: staged.cgImage, cutout: cutout)
        }.value
    }

    private static func build(photo: CGImage, cutout: SubjectCutout) -> PreparedSubject? {
        let w = photo.width, h = photo.height
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let size = CGSize(width: w, height: h)

        // Object-shaped patch of backing paper, then the photo with it on top.
        guard let patch = StagedPhoto.drawing(size, opaque: false, { ctx in
                  ctx.draw(cutout.image, in: full)
                  ctx.setBlendMode(.sourceIn)
                  ctx.setFillColor(gray: backingGray, alpha: 1)
                  ctx.fill(full)
              }),
              let backing = StagedPhoto.drawing(size, opaque: true, { ctx in
                  ctx.draw(photo, in: full)
                  ctx.draw(patch, in: full)
              }) else { return nil }

        let crop = CGRect(
            x: (cutout.bounds.minX * CGFloat(cutout.image.width)).rounded(.down),
            y: (cutout.bounds.minY * CGFloat(cutout.image.height)).rounded(.down),
            width: (cutout.bounds.width * CGFloat(cutout.image.width)).rounded(.up),
            height: (cutout.bounds.height * CGFloat(cutout.image.height)).rounded(.up)
        )
        guard let subject = cutout.image.cropping(to: crop) else { return nil }

        let id = UUID().uuidString
        let fileURL = save(subject, name: id)
        let rows = max(1, Int((CGFloat(columns) * CGFloat(h) / CGFloat(w)).rounded()))
        let particles = DissolveParticle.make(from: backing, columns: columns, rows: rows,
                                              focus: CGPoint(x: cutout.bounds.midX, y: cutout.bounds.midY))
        return PreparedSubject(id: id, subject: UIImage(cgImage: subject), bounds: cutout.bounds,
                               backing: UIImage(cgImage: backing), particles: particles,
                               columns: columns, rows: rows, fileURL: fileURL)
    }

    private static func save(_ image: CGImage, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuestStickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        guard let data = ImageEncoding.png(image), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: - Particle dissolve

/// One tile of the photo that breaks away and drifts off.
nonisolated struct DissolveParticle: Sendable {
    /// Column and row in the grid.
    var column: Int
    var row: Int
    var color: Color
    /// Seconds after the dissolve starts before it breaks away.
    var delay: Double
    var lifetime: Double
    /// Points per second.
    var velocity: CGVector
    var spin: Double

    /// Samples the photo on a grid. Tiles near `focus` (the object, as a
    /// fraction of the photo) go first, so the photo crumbles away from it.
    static func make(from image: CGImage, columns: Int, rows: Int, focus: CGPoint) -> [DissolveParticle] {
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return [] }

        var generator = SplitMix(seed: 0x5EED)
        let aspect = Double(rows) / Double(columns)
        let maxDistance = hypot(1.0, aspect)
        var particles: [DissolveParticle] = []
        particles.reserveCapacity(columns * rows)

        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let i = (row * columns + column) * 4
                let a = Double(pixels[i + 3]) / 255
                guard a > 0.04 else { continue }
                let color = Color(.sRGB, red: Double(pixels[i]) / 255 / a, green: Double(pixels[i + 1]) / 255 / a,
                                  blue: Double(pixels[i + 2]) / 255 / a, opacity: a)

                let nx = (Double(column) + 0.5) / Double(columns)
                let ny = (Double(row) + 0.5) / Double(rows)
                let dx = nx - focus.x, dy = (ny - focus.y) * aspect
                let distance = hypot(dx, dy)
                let outward = distance > 0.001 ? CGVector(dx: dx / distance, dy: dy / distance) : CGVector(dx: 0, dy: -1)
                let speed = 30 + generator.next() * 80

                particles.append(DissolveParticle(
                    column: column,
                    row: row,
                    color: color,
                    delay: distance / maxDistance * 0.55 + generator.next() * 0.3,
                    lifetime: 0.75 + generator.next() * 0.45,
                    velocity: CGVector(
                        dx: outward.dx * speed + (generator.next() * 50 - 15),
                        dy: outward.dy * speed - (30 + generator.next() * 70)
                    ),
                    spin: (generator.next() - 0.5) * 6
                ))
            }
        }
        return particles
    }
}

/// The photo breaking into tiles that drift up and fade: tiles still in place
/// are drawn from the photo itself, loose ones as flat squares of its colour.
private struct ParticleDissolve: View {
    let image: UIImage
    let particles: [DissolveParticle]
    let columns: Int
    let rows: Int
    let origin: Date
    let cornerRadius: CGFloat

    /// Room around the photo for the particles to fly into.
    static let margin: CGFloat = 140
    /// Longest delay plus lifetime.
    static let duration: TimeInterval = 2.1
    /// Wind pushing the particles up and to the right (pt/s²).
    private static let wind = CGVector(dx: 30, dy: -70)

    private var lastDelay: Double { particles.map(\.delay).max() ?? 0 }

    private func drawRemainingPhoto(in context: inout GraphicsContext, rect: CGRect, tile: CGSize, t: Double) {
        var loose = Path()
        for p in particles where t >= p.delay {
            loose.addRect(CGRect(x: rect.minX + CGFloat(p.column) * tile.width,
                                 y: rect.minY + CGFloat(p.row) * tile.height,
                                 width: tile.width, height: tile.height).insetBy(dx: -0.5, dy: -0.5))
        }
        let photo = context.resolve(Image(uiImage: image).resizable())
        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous))
            layer.draw(photo, in: rect)
            layer.blendMode = .destinationOut
            layer.fill(loose, with: .color(.black))
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(origin)
            Canvas { context, size in
                let rect = CGRect(x: Self.margin, y: Self.margin,
                                  width: size.width - Self.margin * 2, height: size.height - Self.margin * 2)
                let tile = CGSize(width: rect.width / CGFloat(columns), height: rect.height / CGFloat(rows))

                // What's left of the photo (nothing once every tile has broken away).
                if t < lastDelay { drawRemainingPhoto(in: &context, rect: rect, tile: tile, t: t) }

                // The loose tiles.
                for p in particles where t >= p.delay {
                    let age = t - p.delay
                    guard age < p.lifetime else { continue }
                    let k = age / p.lifetime
                    let x = rect.minX + (CGFloat(p.column) + 0.5) * tile.width
                        + p.velocity.dx * age + 0.5 * Self.wind.dx * age * age
                    let y = rect.minY + (CGFloat(p.row) + 0.5) * tile.height
                        + p.velocity.dy * age + 0.5 * Self.wind.dy * age * age
                    let side = tile.width * (1 - 0.55 * k)
                    var piece = context
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(p.spin * age))
                    piece.fill(Path(CGRect(x: -side / 2, y: -side / 2, width: side, height: side)),
                               with: .color(p.color.opacity(1 - k * k)))
                }
            }
        }
    }
}

/// Small deterministic random numbers in 0..<1, so the dissolve looks the same each time.
nonisolated private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
