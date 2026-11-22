import SwiftUI
import FogKit

/// The image in a feed post: a square infographic summing up one session.
///
/// TEMPLATE (Justin) — Jonathan owns the final design. Swap the body for the real
/// one; the feed only relies on this contract:
///   • `init(post:)` with a `FeedPost` (FogKit, docs/api.md §8). Available fields:
///     `author` (name, isMe), `startedAt`, `endedAt`, `durationS`, `distanceM`, `newTiles`,
///     `paceSecondsPerKm`, `area` (name, kind; may be nil), `sticker` (url, category,
///     placeName; nil unless a quest was found during the session).
///   • Square (1:1), full card width, rounded corners. The feed adds no padding around it.
/// Formatting helpers: `FeedFormat`, `TerritoryFormat`, `ProfilePage.distanceText`.
/// Routes and positions are deliberately not in the post (privacy).
struct SessionInfographic: View {
    let post: FeedPost

    static let cornerRadius: CGFloat = 22

    var body: some View {
        SideQuestDesign.canvas
            .overlay { ClearedTilesPattern(seed: post.id, filled: post.newTiles) }
            .overlay(alignment: .topLeading) { heading.padding(18) }
            .overlay { centerpiece.padding(.bottom, 70) }
            .overlay(alignment: .bottom) { stats.padding(12) }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    // MARK: Pieces

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(post.sticker == nil ? "EXPEDITION" : "QUEST FOUND")
                .font(SideQuestDesign.ptSans(fixed: 12))
                .tracking(1.6)
                .foregroundStyle(post.sticker == nil ? .white.opacity(0.6) : SideQuestDesign.questActive)
            Text(post.startedAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                .font(SideQuestDesign.calSans(18, relativeTo: nil))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var centerpiece: some View {
        if let find = post.sticker {
            VStack(spacing: 6) {
                AsyncImage(url: find.url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: QuestCategory.symbolName(find.category))
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(SideQuestDesign.questActive)
                    }
                }
                .frame(width: 130, height: 130)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .rotationEffect(.degrees(-6))
                if let place = find.placeName {
                    Text(place)
                        .font(SideQuestDesign.ptSans(fixed: 14))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
        } else {
            VStack(spacing: 0) {
                Text(post.newTiles.formatted())
                    .font(SideQuestDesign.calSans(64, relativeTo: nil))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("tiles of fog cleared")
                    .font(SideQuestDesign.ptSans(fixed: 16))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.top, 20)
        }
    }

    private var stats: some View {
        HStack(spacing: 8) {
            StatTile(label: "Distance", value: ProfilePage.distanceText(post.distanceM), color: SideQuestDesign.travelCard)
            StatTile(label: "Time", value: FeedFormat.duration(post.durationS), color: SideQuestDesign.timeCard)
            if post.sticker != nil {
                StatTile(label: "Tiles", value: post.newTiles.formatted(), color: SideQuestDesign.cityCard)
            } else {
                StatTile(label: "Pace /km", value: FeedFormat.pace(post.paceSecondsPerKm), color: SideQuestDesign.cityCard)
            }
        }
    }

    private var accessibilityText: String {
        var parts = [
            "\(ProfilePage.distanceText(post.distanceM)) in \(FeedFormat.duration(post.durationS))",
            "\(post.newTiles) new tiles",
        ]
        if let find = post.sticker { parts.append("found the \(QuestCategory.displayName(find.category))") }
        return parts.joined(separator: ", ")
    }
}

/// Small solid stat card, same style as the profile's summary cards.
private struct StatTile: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(SideQuestDesign.ptSans(fixed: 13))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            Text(value)
                .font(SideQuestDesign.calSans(22, relativeTo: nil))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color))
    }
}

/// Honeycomb backdrop: a few hexes "cleared" (lit green) among faint fogged ones. More tiles
/// cleared in the session lights more of them. Seeded by the post id so it doesn't shimmer
/// between redraws.
private struct ClearedTilesPattern: View {
    let seed: UUID
    let filled: Int

    var body: some View {
        Canvas { context, size in
            let radius: CGFloat = 16
            let width = sqrt(3) * radius
            let rowHeight = radius * 1.5
            // Up to ~40% of hexes lit, scaling with the session's tiles.
            let share = min(0.08 + Double(filled) / 800, 0.4)
            var rng = SplitMix64(seed: seed)
            var row = 0
            var y: CGFloat = 0
            while y < size.height + radius {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : width / 2
                while x < size.width + width {
                    let hex = Self.hexagon(center: CGPoint(x: x, y: y), radius: radius - 1.5)
                    let lit = Double(rng.next() % 1000) / 1000 < share
                    context.fill(hex, with: .color(lit ? SideQuestDesign.accentGreen.opacity(0.55) : .white.opacity(0.04)))
                    x += width
                }
                y += rowHeight
                row += 1
            }
        }
        // Keep the text readable over the pattern.
        .overlay {
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }

    private static func hexagon(center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 + .pi / 6
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.closeSubpath()
        }
    }
}

private extension SplitMix64 {
    /// Seeded from a UUID's bytes (the generator itself lives in CloudField.swift).
    init(seed: UUID) {
        let b = seed.uuid
        self.init(seed: [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
            .reduce(0) { $0 &* 31 &+ UInt64($1) })
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
