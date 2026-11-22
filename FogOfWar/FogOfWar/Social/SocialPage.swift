import SwiftUI
import FogKit

/// First tab: the activity feed. Every finished session is a post (author, when, where, and a
/// session infographic), newest first, in one scrolling column like Instagram. Pull to refresh;
/// older posts load as you reach the bottom. Data: `services.feed` (docs/api.md §8).
///
/// There's no friends list yet, so the feed shows every player's sessions.
struct SocialPage: View {
    /// Extra room at the bottom for the tab bar floating over the page.
    var bottomInset: CGFloat = 0

    @Environment(FogServices.self) private var services

    static let horizontalMargin: CGFloat = 20

    private var feed: FeedModel { services.feed }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 30)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)

                content
            }
            .padding(.bottom, bottomInset)
        }
        .scrollIndicators(.hidden)
        .refreshable { await feed.refresh() }
        .background(SideQuestDesign.profileSurface.ignoresSafeArea())
        .task {
            if !feed.hasLoaded { await feed.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(SideQuestDesign.calSans(22))
                .tracking(-0.22)
                .foregroundStyle(.black)
            Text("Everyone's latest sessions")
                .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                .tracking(-0.51)
                .foregroundStyle(.black)
        }
        .padding(.leading, 5)
        .padding(.top, 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Feed

    @ViewBuilder
    private var content: some View {
        if !feed.posts.isEmpty {
            ForEach(feed.posts) { post in
                FeedPostCard(post: post)
                    .padding(.horizontal, Self.horizontalMargin)
                    .padding(.bottom, 28)
                    .task { await feed.loadMoreIfNeeded(after: post) }
            }
            if feed.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if !feed.hasMore {
                Text("You're all caught up")
                    .font(SideQuestDesign.ptSans(15, relativeTo: .footnote))
                    .foregroundStyle(SideQuestDesign.tabInactive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        } else if feed.lastError != nil, !feed.isLoading {
            message(
                symbol: "wifi.exclamationmark",
                title: "Couldn't load the feed",
                detail: "Check your connection and try again.",
                action: ("Try again", { Task { await feed.refresh() } })
            )
        } else if feed.hasLoaded, !feed.isLoading {
            message(
                symbol: "figure.walk",
                title: "No sessions yet",
                detail: "Finish an expedition and it shows up here for everyone.",
                action: nil
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        }
    }

    private func message(symbol: String, title: String, detail: String,
                         action: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(SideQuestDesign.accentGreen)
            Text(title)
                .font(SideQuestDesign.calSans(20, relativeTo: .title3))
                .foregroundStyle(.black)
            Text(detail)
                .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                .foregroundStyle(SideQuestDesign.boardLabelText)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().fill(SideQuestDesign.primaryText))
                    .foregroundStyle(SideQuestDesign.pillText)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}

// MARK: - Post

/// One post: author row, the session infographic, then a one-line caption.
struct FeedPostCard: View {
    let post: FeedPost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            authorRow
            SessionInfographic(post: post)
            caption
        }
        .accessibilityElement(children: .combine)
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            PlayerAvatar(name: post.author.name, size: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text(post.author.isMe ? "You" : post.author.name)
                    .font(SideQuestDesign.calSans(17, relativeTo: .headline))
                    .tracking(-0.17)
                    .foregroundStyle(SideQuestDesign.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let area = post.area {
                        Image(systemName: TerritoryFormat.symbol(for: area.kind))
                            .font(.system(size: 11, weight: .semibold))
                        Text(area.name)
                        Text("·")
                    }
                    Text(FeedFormat.ago(post.endedAt))
                }
                .font(SideQuestDesign.ptSans(14, relativeTo: .footnote))
                .foregroundStyle(SideQuestDesign.boardLabelText)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var caption: some View {
        Text(FeedFormat.caption(for: post))
            .font(SideQuestDesign.ptSans(16, relativeTo: .body))
            .tracking(-0.3)
            .foregroundStyle(SideQuestDesign.primaryText)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Round initial on a colour picked from the name, so a player always gets the same one.
struct PlayerAvatar: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        let palette = [SideQuestDesign.cityCard, SideQuestDesign.travelCard, SideQuestDesign.timeCard]
        let index = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        Text(name.prefix(1).uppercased())
            .font(SideQuestDesign.calSans(size * 0.47, relativeTo: nil))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(palette[index]))
            .accessibilityHidden(true)
    }
}

// MARK: - Formatting

enum FeedFormat {
    /// "now", "12m", "3h", "2d", then a short date, like Instagram.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    static func duration(_ seconds: Int) -> String {
        TerritoryFormat.duration(Double(seconds))
    }

    /// Minutes:seconds per km, e.g. "12'40\"".
    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite else { return "–" }
        let total = Int(secondsPerKm.rounded())
        return "\(total / 60)'\(String(format: "%02d", total % 60))\""
    }

    static func caption(for post: FeedPost) -> String {
        let who = post.author.isMe ? "You" : post.author.name
        let tiles = post.newTiles == 1 ? "1 new tile" : "\(post.newTiles.formatted()) new tiles"
        var text = "\(who) cleared \(tiles)"
        if let area = post.area { text += " around \(area.name)" }
        if let find = post.sticker {
            text += " and found the \(QuestCategory.displayName(find.category))"
            if let place = find.placeName { text += " at \(place)" }
        }
        return text + "."
    }
}
