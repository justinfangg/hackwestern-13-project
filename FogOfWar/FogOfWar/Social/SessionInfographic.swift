import SwiftUI
import FogKit

/// The image in a feed post: a square card summing up one session.
///
/// It is the profile's sticker stats page (Figma 10:46) wrapped into a card: the
/// sticker (when a quest was found) on a blurred wash of its own colors, Distance
/// and Time, the route line, and the date. The route comes only as a shape
/// (`FeedPost.routeShape`, no coordinates), so it's drawn on its own, without a map.
/// The feed only relies on this contract:
///   • `init(post:)` with a `FeedPost` (FogKit, docs/api.md §8).
///   • Square (1:1), full card width, rounded corners. The feed adds no padding around it.
struct SessionInfographic: View {
    let post: FeedPost

    static let cornerRadius: CGFloat = 22

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { GeometryReader { FeedCard(post: post, width: $0.size.width) } }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.06), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(ProfilePage.distanceText(post.distanceM)) in \(FeedFormat.duration(post.durationS))"]
        if let find = post.sticker { parts.append("found the \(QuestCategory.displayName(find.category))") }
        if post.routeShape != nil { parts.append("route drawn") }
        parts.append(post.startedAt.formatted(.dateTime.month(.wide).day().year()))
        return parts.joined(separator: ", ")
    }
}

/// The card's contents, laid out like the stats page (403 pt wide) scaled to the card.
/// The sticker is downloaded once, then given the same white cutout outline as on
/// the memory board.
private struct FeedCard: View {
    let post: FeedPost
    let width: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var artwork: UIImage?
    @State private var outlined: UIImage?

    private static let ink = Color(red: 0x3B / 255, green: 0x3B / 255, blue: 0x3B / 255)

    private var k: CGFloat { width / 403 }
    /// Green when the session found a quest, orange otherwise (the map's route colors).
    private var routeColor: Color {
        post.sticker == nil ? SideQuestDesign.questActive : SideQuestDesign.questCompleted
    }
    /// The sticker's box at the top of the card.
    private var stickerBox: CGSize { CGSize(width: width * 0.58, height: width * 0.30) }

    var body: some View {
        ZStack {
            SideQuestDesign.profileSurface
            backdrop
            RecapDotField()

            VStack(spacing: 0) {
                if let find = post.sticker {
                    sticker(find)
                        .frame(height: width * 0.36)
                        .padding(.top, width * 0.04)
                } else {
                    Spacer().frame(height: width * 0.08)
                }

                HStack(alignment: .top, spacing: 0) {
                    stat(label: "Distance", value: ProfilePage.distanceText(post.distanceM))
                    stat(label: "Time", value: FeedFormat.duration(post.durationS))
                }
                .padding(.horizontal, 24 * k)

                RouteShapeLine(points: post.routeShape, color: routeColor, lineWidth: 5)
                    .padding(.horizontal, width * 0.2)
                    .padding(.vertical, width * 0.035)
                    .frame(maxHeight: .infinity)

                Text(post.startedAt.formatted(.dateTime.month(.wide).day().year()))
                    .font(SideQuestDesign.ptSans(fixed: 13))
                    .tracking(-0.3)
                    .foregroundStyle(Self.ink.opacity(0.6))
                    .padding(.bottom, 16)
            }
        }
        .frame(width: width, height: width)
        .task(id: post.sticker?.url) { await load() }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(SideQuestDesign.ptSans(fixed: 17 * k))
                .tracking(-0.51)
            Text(value)
                .font(SideQuestDesign.calSans(38.911 * k, relativeTo: nil))
                .tracking(-0.39)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(Self.ink)
        .frame(maxWidth: .infinity)
    }

    // The wash: the sticker's own colors, hugely blurred (Figma "Map Image" 10:59),
    // or a soft glow in the route's color when there's no sticker.
    @ViewBuilder
    private var backdrop: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: width * 1.5, height: width * 1.1)
                .clipped()
                .rotationEffect(.degrees(13))
                .blur(radius: width * 0.2)
                .opacity(0.6)
                .position(x: width * 0.52, y: width * 0.25)
                .frame(width: width, height: width)
                .clipped()
                .allowsHitTesting(false)
        } else {
            RadialGradient(
                colors: [routeColor.opacity(0.22), .clear],
                center: UnitPoint(x: 0.5, y: post.sticker == nil ? 0.6 : 0.25),
                startRadius: 0,
                endRadius: width * 0.6
            )
        }
    }

    private func sticker(_ find: FeedPost.Find) -> some View {
        Group {
            if let outlined {
                Image(uiImage: outlined)
                    .resizable()
                    .scaledToFit()
                    .frame(width: stickerBox.width, height: stickerBox.height)
            } else {
                Image(systemName: QuestCategory.symbolName(find.category))
                    .font(.system(size: width * 0.1, weight: .semibold))
                    .foregroundStyle(SideQuestDesign.questActive)
                    .frame(width: width * 0.24, height: width * 0.24)
                    .background(Circle().fill(.white))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .rotationEffect(.degrees(-6))
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let find = post.sticker else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: find.url),
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return }

        let outline = width * 0.02
        let pad = StickerOutline.padding(for: outline)
        let bounds = CGSize(width: stickerBox.width - pad * 2, height: stickerBox.height - pad * 2)
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let art = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let scale = displayScale
        let id = find.url.absoluteString
        let rendered = await Task.detached(priority: .userInitiated) {
            StickerOutline.render(image, cacheKey: "feed.\(id)", canvas: art,
                                  imageRect: CGRect(origin: .zero, size: art),
                                  thickness: outline, scale: scale)
        }.value

        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            artwork = image
            outlined = rendered
        }
    }
}

/// Draws `FeedPost.routeShape` (points in a unit square) as a rounded line, fitted
/// and centred in the space it's given. Draws nothing without a shape.
struct RouteShapeLine: View {
    let points: [FeedPost.ShapePoint]?
    let color: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            guard let points, points.count >= 2 else { return }
            let side = max(min(size.width, size.height) - lineWidth, 1)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            var path = Path()
            for (i, p) in points.enumerated() {
                let point = CGPoint(x: origin.x + p.x * side, y: origin.y + p.y * side)
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            ForEach(MockFogAPI.sampleFeed().prefix(3)) { FeedPostCard(post: $0) }
        }
        .padding(20)
    }
    .background(SideQuestDesign.profileSurface)
}
