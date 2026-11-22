import SwiftUI
import FogKit

/// Territory leaderboards: who has explored the most of each campus, park and neighbourhood,
/// by % of the area, time spent in it, or distance walked in it (docs/api.md §7).
/// Styled like the profile page: light rounded container on the dark canvas, Cal Sans + PT Sans,
/// solid stat cards.
struct LeaderboardPage: View {
    let initialMetric: LeaderboardMetric
    /// Off when the page is a tab (there's nothing to dismiss).
    var showsCloseButton = true
    /// Extra room at the bottom, e.g. for the tab bar floating over the page.
    var bottomInset: CGFloat = 0
    /// As a tab, the light surface fills the whole page and the parent rounds
    /// it to the screen's corners. Otherwise it's a rounded card on the canvas.
    var fillsScreen = false

    @Environment(FogServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    private static let horizontalMargin: CGFloat = 28

    private var model: LeaderboardModel { services.leaderboard }

    var body: some View {
        ZStack {
            SideQuestDesign.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 30)
                    .padding(.horizontal, Self.horizontalMargin)

                metricCards
                    .padding(.top, 22)
                    .padding(.horizontal, Self.horizontalMargin)

                ranking
                    .padding(.top, 18)
                    .padding(.bottom, bottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                if fillsScreen {
                    SideQuestDesign.profileSurface.ignoresSafeArea()
                } else {
                    RoundedRectangle(cornerRadius: SideQuestDesign.containerCornerRadius, style: .continuous)
                        .fill(SideQuestDesign.profileSurface)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .padding(.top, fillsScreen ? 0 : 8)
        }
        .task {
            let here = services.location.currentCoordinate ?? services.location.displayCoordinate
            await model.load(near: here, metric: initialMetric)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Leaderboard")
                    .font(SideQuestDesign.calSans(22))
                    .tracking(-0.22)
                    .foregroundStyle(.black)
                Text(subtitle)
                    .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                    .tracking(-0.51)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.leading, 5)
            .padding(.top, 3)

            Spacer(minLength: 12)

            periodMenu
                .padding(.top, 6)

            if showsCloseButton {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SideQuestDesign.primaryText)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(.white))
                        .overlay(Circle().stroke(SideQuestDesign.boardBorder, lineWidth: 1))
                }
                .accessibilityLabel("Close leaderboard")
            }
        }
    }

    private var subtitle: String {
        guard let board = model.board, let city = board.area else { return "Who's explored the most" }
        let players = board.totalPlayers
        return (players == 1 ? "1 explorer" : "\(players) explorers") + " in \(city.name)"
    }

    /// Day / week / month dropdown.
    private var periodMenu: some View {
        Menu {
            Picker("Period", selection: Binding(
                get: { model.period },
                set: { period in Task { await model.select(period: period) } }
            )) {
                ForEach(LeaderboardPeriod.allCases) { period in
                    Text(TerritoryFormat.label(for: period)).tag(period)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(TerritoryFormat.label(for: model.period))
                    .font(SideQuestDesign.ptSans(fixed: 16))
                    .tracking(-0.3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(SideQuestDesign.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(.white))
            .overlay(Capsule().stroke(SideQuestDesign.boardBorder, lineWidth: 1))
        }
        .accessibilityLabel("Period: \(TerritoryFormat.label(for: model.period))")
    }

    // MARK: Metrics (your own numbers in this city and period)

    private var metricCards: some View {
        HStack(spacing: 12) {
            ForEach(LeaderboardMetric.allCases) { metric in
                MetricCard(
                    metric: metric,
                    value: model.board.map { TerritoryFormat.value($0.mine.value(for: metric), metric: metric) } ?? "–",
                    isSelected: metric == model.metric
                ) {
                    Task { await model.select(metric: metric) }
                }
            }
        }
    }

    // MARK: Ranking

    @ViewBuilder
    private var ranking: some View {
        if let board = model.board {
            if board.area == nil {
                message(symbol: "map", title: "No leaderboard here yet",
                        detail: "Leaderboards cover London for now.")
            } else if board.entries.isEmpty {
                message(symbol: "flag.checkered",
                        title: "No one has explored \(board.area?.name ?? "here") \(TerritoryFormat.phrase(for: board.period)) yet",
                        detail: "Head out to claim the top spot.")
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(board.entries) { entry in
                                RankRow(entry: entry, metric: board.metric)
                            }
                        }
                        .padding(.horizontal, Self.horizontalMargin - 8)
                        .padding(.bottom, 24)
                    }
                    if let me = board.me, !board.entries.contains(where: \.isMe) {
                        RankRow(entry: me, metric: board.metric)
                            .padding(.horizontal, Self.horizontalMargin - 8)
                            .padding(.vertical, 10)
                            .background(SideQuestDesign.profileSurface.shadow(.drop(color: .black.opacity(0.08), radius: 8, y: -2)))
                    }
                }
                .refreshable { await model.refresh() }
            }
        } else if let error = model.lastError, !model.isLoading {
            VStack(spacing: 12) {
                Text("Couldn't load the leaderboard.")
                    .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                    .foregroundStyle(SideQuestDesign.boardLabelText)
                Button("Try again") {
                    Task { await model.load(near: services.location.currentCoordinate ?? services.location.displayCoordinate) }
                }
                .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Capsule().fill(SideQuestDesign.primaryText))
                .foregroundStyle(SideQuestDesign.pillText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHint(error)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(SideQuestDesign.cityCard)
            Text(title)
                .font(SideQuestDesign.calSans(20, relativeTo: .title3))
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
            Text(detail)
                .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                .foregroundStyle(SideQuestDesign.boardLabelText)
        }
        .padding(.horizontal, Self.horizontalMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// Same shape as the profile's stat cards: label top-right, big value bottom-left.
private struct MetricCard: View {
    let metric: LeaderboardMetric
    let value: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Only the selected metric is in colour; the others are greyed out.
            (isSelected ? TerritoryFormat.color(for: metric) : SideQuestDesign.metricInactive)
                .frame(maxWidth: .infinity)
                .frame(height: 75)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: TerritoryFormat.symbol(for: metric))
                            .font(.system(size: 12, weight: .semibold))
                        Text(TerritoryFormat.label(for: metric))
                            .font(SideQuestDesign.ptSans(fixed: 15))
                            .tracking(-0.45)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.trailing, 10)
                    .padding(.top, 8)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(value)
                        .font(SideQuestDesign.calSans(28, relativeTo: nil))
                        .tracking(-0.28)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(isSelected ? 1 : 0.96)
                .animation(.spring(duration: 0.3, bounce: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rank by \(TerritoryFormat.label(for: metric)). You: \(value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RankRow: View {
    let entry: LeaderboardEntry
    let metric: LeaderboardMetric

    var body: some View {
        HStack(spacing: 12) {
            rankBadge
            avatar
            Text(entry.isMe ? "\(entry.name) (you)" : entry.name)
                .font(SideQuestDesign.ptSans(17, relativeTo: .body))
                .tracking(-0.51)
                .foregroundStyle(SideQuestDesign.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(TerritoryFormat.value(entry.value, metric: metric))
                .font(SideQuestDesign.calSans(20, relativeTo: .title3))
                .tracking(-0.2)
                .foregroundStyle(SideQuestDesign.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 54)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(entry.isMe ? SideQuestDesign.questActive.opacity(0.28) : .white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(entry.isMe ? SideQuestDesign.questActive : SideQuestDesign.boardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.isMe ? "you, " : "")\(entry.name), \(TerritoryFormat.value(entry.value, metric: metric))")
    }

    private var rankBadge: some View {
        let medal: Color? = switch entry.rank {
        case 1: Color(red: 0xF2 / 255, green: 0xB5 / 255, blue: 0x2A / 255)
        case 2: Color(red: 0xB8 / 255, green: 0xBF / 255, blue: 0xC6 / 255)
        case 3: Color(red: 0xC8 / 255, green: 0x84 / 255, blue: 0x4E / 255)
        default: nil
        }
        return Text("\(entry.rank)")
            .font(SideQuestDesign.calSans(18, relativeTo: nil))
            .foregroundStyle(medal == nil ? SideQuestDesign.boardLabelText : .white)
            .frame(width: 32, height: 32)
            .background { if let medal { Circle().fill(medal) } }
    }

    private var avatar: some View {
        PlayerAvatar(name: entry.name, size: 34)
    }
}

// MARK: - Formatting

extension SideQuestDesign {
    /// Third stat colour for "time explored", alongside the city (green) and travel (blue) cards.
    static let timeCard = Color(red: 0x9A / 255, green: 0x5B / 255, blue: 0x1E / 255)
    /// Unselected leaderboard metric cards.
    static let metricInactive = Color(red: 0xB4 / 255, green: 0xB6 / 255, blue: 0xB4 / 255)
}

enum TerritoryFormat {
    static func value(_ value: Double, metric: LeaderboardMetric) -> String {
        switch metric {
        case .percent: percent(value)
        case .distance: ProfilePage.distanceText(value)
        case .time: duration(value)
        }
    }

    /// A city is big, so a day's or week's share is tiny: keep two decimals below 1%.
    static func percent(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value >= 1 { return ProfilePage.percentText(value) }
        if value < 0.01 { return "<0.01%" }
        return value.formatted(.number.precision(.fractionLength(2))) + "%"
    }

    static func label(for period: LeaderboardPeriod) -> String {
        switch period {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        }
    }

    /// "today", "this week", "this month" (inside a sentence).
    static func phrase(for period: LeaderboardPeriod) -> String {
        label(for: period).lowercased()
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func label(for metric: LeaderboardMetric) -> String {
        switch metric {
        case .percent: "Explored"
        case .time: "Time"
        case .distance: "Distance"
        }
    }

    static func symbol(for metric: LeaderboardMetric) -> String {
        switch metric {
        case .percent: "map.fill"
        case .time: "clock.fill"
        case .distance: "figure.walk"
        }
    }

    static func color(for metric: LeaderboardMetric) -> Color {
        switch metric {
        case .percent: SideQuestDesign.cityCard
        case .time: SideQuestDesign.timeCard
        case .distance: SideQuestDesign.travelCard
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "campus": "building.columns.fill"
        case "park": "leaf.fill"
        case "neighbourhood": "house.fill"
        default: "mappin"
        }
    }
}
