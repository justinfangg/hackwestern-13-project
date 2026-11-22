import SwiftUI

/// The app's three top-level pages, in tab-bar order (left to right).
enum MainTab: Int, CaseIterable, Identifiable {
    case social, map, leaderboard

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .social: "Social"
        case .map: "Map"
        case .leaderboard: "Leaderboard"
        }
    }
}

/// Figma 55:3722 bottom navigation: three bare icons with a white pill behind
/// the selected one. The pill slides between tabs.
struct MainTabBar: View {
    @Binding var selection: MainTab

    static let height: CGFloat = 53
    /// Gap between the pill's bottom edge and the screen's bottom edge.
    static let bottomMargin: CGFloat = 14
    /// Total vertical space the tab bar takes at the bottom of the screen.
    static var reservedHeight: CGFloat { height + bottomMargin }

    private static let pillWidth: CGFloat = 99
    /// Distance between neighbouring tab icons' centers.
    private static let tabSpacing: CGFloat = 94

    var body: some View {
        ZStack {
            Capsule()
                .fill(.white)
                .frame(width: Self.pillWidth, height: Self.height)
                .offset(x: CGFloat(selection.rawValue - MainTab.map.rawValue) * Self.tabSpacing)
                // Slides in step with the pages.
                .animation(MainView.tabTransition, value: selection)

            HStack(spacing: 0) {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        icon(for: tab, isSelected: tab == selection)
                            .frame(width: Self.tabSpacing, height: Self.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(tab == selection ? .isSelected : [])
                }
            }
        }
        .frame(height: Self.height)
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func icon(for tab: MainTab, isSelected: Bool) -> some View {
        let tint = isSelected ? SideQuestDesign.accentGreen : SideQuestDesign.tabInactive
        switch tab {
        case .social:
            SocialTabIcon(stroke: tint)
        case .map:
            Image("TabGlobe")
                .renderingMode(.template)
                .foregroundStyle(tint)
        case .leaderboard:
            Image("TabTrophy")
                .renderingMode(.template)
                .foregroundStyle(tint)
        }
    }
}

/// Figma "Control Button": two stacked rounded cards, the top one tilted 7.64°.
private struct SocialTabIcon: View {
    let stroke: Color

    private static let size: CGFloat = 26.96
    private static let lineWidth: CGFloat = 2.696

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
            card
                .rotationEffect(.degrees(7.64))
                .offset(x: 3.59 + (30.304 - Self.size) / 2, y: 2.7 + (30.304 - Self.size) / 2)
        }
        .frame(width: 34, height: 33, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 6.291, style: .continuous)
        return shape
            .fill(SideQuestDesign.tabIconFill)
            .overlay(shape.strokeBorder(stroke, lineWidth: Self.lineWidth))
            .frame(width: Self.size, height: Self.size)
    }
}
