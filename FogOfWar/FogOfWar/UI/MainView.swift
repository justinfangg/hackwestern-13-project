import SwiftUI
import FogKit

/// Root layout (Figma 55:3722): three full-screen pages (Social, Map,
/// Leaderboard) side by side, switched with the bottom tab bar. Changing tab
/// slides the row of pages left or right. The profile opens from the map's
/// top-right button (see `MapPage`).
struct MainView: View {
    @State private var selection: MainTab = .map
    /// Pages are built the first time they're shown, so e.g. the leaderboard
    /// doesn't load at launch before there's a location fix.
    @State private var visited: Set<MainTab> = [.map]
    @Environment(FogServices.self) private var services

    var body: some View {
        // Read the real insets here (this reader respects the safe area), then
        // lay the pages out edge to edge.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let screen = CGSize(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom
            )
            content(size: screen, safeArea: insets)
                .frame(width: screen.width, height: screen.height)
                .ignoresSafeArea()
        }
        .onChange(of: selection) { _, tab in visited.insert(tab) }
        .onChange(of: isOnQuest) { _, onQuest in
            // A quest is always played on the map.
            if onQuest { selection = .map }
        }
    }

    private func content(size: CGSize, safeArea: EdgeInsets) -> some View {
        ZStack(alignment: .bottom) {
            SideQuestDesign.canvas

            HStack(spacing: 0) {
                ForEach(MainTab.allCases) { tab in
                    page(tab, size: size, safeArea: safeArea)
                        .frame(width: size.width, height: size.height)
                        // Each page is a card with the display's own corners, so
                        // the canvas shows between them while sliding.
                        .clipShape(RoundedRectangle(cornerRadius: SideQuestDesign.screenCornerRadius, style: .continuous))
                        // Off-screen pages are inert and hidden from VoiceOver.
                        .allowsHitTesting(tab == selection)
                        .accessibilityHidden(tab != selection)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
            .offset(x: -CGFloat(selection.rawValue) * size.width)
            .animation(Self.tabTransition, value: selection)

            MainTabBar(selection: tabSelection)
                .padding(.bottom, MainTabBar.bottomMargin)
                .offset(y: isOnQuest ? MainTabBar.reservedHeight + 20 : 0)
                .opacity(isOnQuest ? 0 : 1)
                .allowsHitTesting(!isOnQuest)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(Self.questTransition, value: isOnQuest)
    }

    @ViewBuilder
    private func page(_ tab: MainTab, size: CGSize, safeArea: EdgeInsets) -> some View {
        switch tab {
        case .social:
            if visited.contains(.social) {
                SocialPage().safeAreaPadding(safeArea)
            } else {
                SideQuestDesign.canvas
            }
        case .map:
            MapPage(fullSize: size, safeArea: safeArea)
        case .leaderboard:
            if visited.contains(.leaderboard) {
                LeaderboardPage(
                    initialMetric: .percent,
                    showsCloseButton: false,
                    bottomInset: max(MainTabBar.reservedHeight - safeArea.bottom, 0) + 8,
                    fillsScreen: true
                )
                // The pages are laid out edge to edge; give them back the real insets.
                .safeAreaPadding(safeArea)
            } else {
                SideQuestDesign.canvas
            }
        }
    }

    /// Tab bar selection. A page opened for the first time is built before the
    /// slide starts; otherwise building it eats the animation and the page
    /// just jumps into place.
    private var tabSelection: Binding<MainTab> {
        Binding {
            selection
        } set: { tab in
            guard tab != selection else { return }
            guard !visited.contains(tab) else {
                selection = tab
                return
            }
            visited.insert(tab)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                selection = tab
            }
        }
    }

    /// Used when sliding between tabs: quick, and settles without overshooting.
    static let tabTransition: Animation = .spring(duration: 0.3, bounce: 0)

    /// Spring used for entering/leaving the active-quest layout.
    static let questTransition: Animation = .spring(duration: 0.6, bounce: 0.14)

    /// A quest is "accepted" while its expedition is recording.
    private var isOnQuest: Bool { services.expeditions.active != nil }
}
