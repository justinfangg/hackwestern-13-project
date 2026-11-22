import SwiftUI
import FogKit

/// Root layout from Figma: the map page and the profile page sit in two
/// rounded containers on a dark canvas. The handle in the gap between them
/// drags the split, which settles fully on one page or the other with spring
/// physics (no halfway stop).
struct MainView: View {
    enum SplitDetent: CaseIterable {
        /// Map fills the screen; the profile peeks at the bottom (Figma default).
        case map
        /// Profile fills the screen; a strip of map stays visible on top (Figma 42:2159).
        case profile
    }

    @State private var detent: SplitDetent = .map
    /// Live split position while dragging/settling. `nil` means "at `detent`".
    @State private var mapHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?
    @Environment(FogServices.self) private var services

    var body: some View {
        // Read the real insets here (this reader respects the safe area), then
        // lay the canvas out edge to edge.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let screen = CGSize(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom
            )
            content(metrics: SplitMetrics(size: screen, safeArea: insets))
                .frame(width: screen.width, height: screen.height)
                .ignoresSafeArea()
                .onChange(of: screen) {
                    // Re-anchor to the settled detent on size changes.
                    mapHeight = nil
                }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: detent)
    }

    private func content(metrics: SplitMetrics) -> some View {
        // Accepting a quest takes the map (almost) full screen (Figma 16:238):
        // the profile slides away and the split handle is retired.
        let height = isOnQuest
            ? metrics.questMapHeight
            : mapHeight ?? metrics.height(for: detent)
        let cornerRadius = isOnQuest ? 0 : SideQuestDesign.containerCornerRadius

        return ZStack(alignment: .top) {
            SideQuestDesign.canvas

            ProfilePage(contentHeight: metrics.profileContentHeight)
                .frame(width: metrics.size.width, height: metrics.size.height)
                .offset(y: height + SideQuestDesign.splitGap)

            MapPage(
                visibleHeight: height,
                fullSize: metrics.size,
                safeArea: metrics.safeArea
            )
            .frame(width: metrics.size.width, height: max(height, 0))
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
            // The map is only a backdrop while the profile is open: no panning
            // it, and touches can't leak through to it from the profile.
            .allowsHitTesting(isOnQuest || (detent == .map && dragStartHeight == nil))

            splitHandle(metrics: metrics, currentHeight: height)
                .offset(y: height + SideQuestDesign.splitGap / 2 - Self.handleHitHeight / 2)
                .opacity(isOnQuest ? 0 : 1)
                .allowsHitTesting(!isOnQuest)
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .top)
        // Also covers a quest ending from elsewhere (e.g. the recap flow).
        .animation(Self.questTransition, value: isOnQuest)
    }

    /// Spring used for entering/leaving the active-quest layout.
    static let questTransition: Animation = .spring(duration: 0.6, bounce: 0.14)

    /// A quest is "accepted" while its expedition is recording.
    private var isOnQuest: Bool { services.expeditions.active != nil }

    private static let handleHitHeight: CGFloat = 52

    /// Map height with the profile open: Figma's 88 pt strip on a 62 pt status
    /// bar, i.e. 26 pt of map below the status bar.
    static func collapsedMapHeight(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + 26
    }

    private func splitHandle(metrics: SplitMetrics, currentHeight: CGFloat) -> some View {
        Capsule()
            .fill(SideQuestDesign.splitHandle)
            .frame(width: 66, height: 6)
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? currentHeight
                        if dragStartHeight == nil { dragStartHeight = start }
                        mapHeight = SpringDetents.rubberBanded(
                            start + value.translation.height,
                            in: metrics.range,
                            dimension: metrics.size.height
                        )
                    }
                    .onEnded { value in
                        let current = mapHeight ?? currentHeight
                        let velocity = value.velocity.height
                        let targetHeight = SpringDetents.target(
                            from: current,
                            velocity: velocity,
                            detents: SplitDetent.allCases.map(metrics.height(for:))
                        )
                        dragStartHeight = nil
                        settle(
                            to: metrics.detent(nearest: targetHeight),
                            from: current,
                            velocity: velocity,
                            metrics: metrics
                        )
                    }
            )
            .onTapGesture {
                settle(to: detent == .map ? .profile : .map, from: currentHeight, velocity: 0, metrics: metrics)
            }
            .accessibilityElement()
            .accessibilityLabel("Map and profile divider")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Swipe up or down to resize the map and profile")
            .accessibilityAdjustableAction { direction in
                let all = SplitDetent.allCases
                guard let index = all.firstIndex(of: detent) else { return }
                switch direction {
                case .increment where index > 0:
                    settle(to: all[index - 1], from: currentHeight, velocity: 0, metrics: metrics)
                case .decrement where index < all.count - 1:
                    settle(to: all[index + 1], from: currentHeight, velocity: 0, metrics: metrics)
                default:
                    break
                }
            }
    }

    private var accessibilityValue: String {
        switch detent {
        case .map: "Map expanded"
        case .profile: "Profile expanded"
        }
    }

    private func settle(to newDetent: SplitDetent, from current: CGFloat, velocity: CGFloat, metrics: SplitMetrics) {
        let target = metrics.height(for: newDetent)
        detent = newDetent
        withAnimation(SpringDetents.snapAnimation(from: current, to: target, velocity: velocity)) {
            mapHeight = target
        }
    }
}

/// Geometry for the map/profile split, derived from the Figma frames
/// (874 pt tall: map 786 pt, 21 pt gap, profile peeking below; with the
/// profile open the map shrinks to an 88 pt strip under the status bar).
private struct SplitMetrics {
    let size: CGSize
    let safeArea: EdgeInsets

    private var profilePeek: CGFloat { 67 }
    private var minimumMapHeight: CGFloat { MainView.collapsedMapHeight(safeAreaTop: safeArea.top) }

    /// Height of the profile container when it's fully open.
    var profileContentHeight: CGFloat {
        size.height - height(for: .profile) - SideQuestDesign.splitGap
    }

    /// Map height while a quest is active: edge to edge. (Figma stops 10 pt
    /// short, which reads as a stray dark band against the device's corners.)
    var questMapHeight: CGFloat { size.height }

    var range: ClosedRange<CGFloat> {
        height(for: .profile) ... height(for: .map)
    }

    func height(for detent: MainView.SplitDetent) -> CGFloat {
        switch detent {
        case .map:
            max(size.height - SideQuestDesign.splitGap - profilePeek, minimumMapHeight)
        case .profile:
            minimumMapHeight
        }
    }

    func detent(nearest height: CGFloat) -> MainView.SplitDetent {
        MainView.SplitDetent.allCases.min { abs(self.height(for: $0) - height) < abs(self.height(for: $1) - height) } ?? .map
    }
}

