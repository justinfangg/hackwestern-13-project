import SwiftUI

/// The "Quests" pill at the bottom of the map. Like the Apple Maps sheet it can
/// be dragged (or tapped) open, here up to half the map container's height,
/// using the same spring physics as the map/profile split.
struct QuestSheet<Content: View>: View {
    static var collapsedHeight: CGFloat { 53 }
    private static var cornerRadius: CGFloat { collapsedHeight / 2 }

    /// Tallest the sheet may grow (top edge at the map's midpoint).
    let maxHeight: CGFloat
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    /// Live height while dragging/settling. `nil` means "at the detent".
    @State private var liveHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?

    private var expandedHeight: CGFloat { max(maxHeight, Self.collapsedHeight) }
    private var height: CGFloat { liveHeight ?? (isExpanded ? expandedHeight : Self.collapsedHeight) }

    private var progress: CGFloat {
        let range = expandedHeight - Self.collapsedHeight
        guard range > 1 else { return 0 }
        return min(max((height - Self.collapsedHeight) / range, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(Double(min(max((progress - 0.25) / 0.55, 0), 1)))
                .allowsHitTesting(progress > 0.6)
                .accessibilityHidden(!isExpanded)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .overlay(alignment: .top) {
            Capsule()
                .fill(SideQuestDesign.sheetGrabber)
                .frame(width: 66, height: 6)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06 + 0.06 * progress), radius: 10 + 8 * progress, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .gesture(dragGesture)
        .onChange(of: isExpanded) { _, expanded in
            // External changes (e.g. tapping a quest on the map) animate too.
            let target = expanded ? expandedHeight : Self.collapsedHeight
            guard dragStartHeight == nil, abs(height - target) > 0.5 else { return }
            settle(expanded: expanded, from: height, velocity: 0)
        }
        .onChange(of: maxHeight) {
            // Track the split resizing the map instead of animating separately.
            if dragStartHeight == nil { liveHeight = nil }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
    }

    private var header: some View {
        HStack {
            Text("Quests")
                .font(SideQuestDesign.ptSans(20))
                .tracking(-0.6)
                .foregroundStyle(SideQuestDesign.primaryText)
            Spacer(minLength: 12)
            Image("QuestsGlobe")
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
        .frame(height: Self.collapsedHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            settle(expanded: !isExpanded, from: height, velocity: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses the quest sheet" : "Shows today's quest")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartHeight ?? height
                if dragStartHeight == nil { dragStartHeight = start }
                liveHeight = SpringDetents.rubberBanded(
                    start - value.translation.height,
                    in: Self.collapsedHeight ... expandedHeight,
                    dimension: max(expandedHeight, 200)
                )
            }
            .onEnded { value in
                let current = height
                // Upward is positive for the sheet's height.
                let velocity = -value.velocity.height
                let target = SpringDetents.target(
                    from: current,
                    velocity: velocity,
                    detents: [Self.collapsedHeight, expandedHeight]
                )
                dragStartHeight = nil
                settle(expanded: target > Self.collapsedHeight + 1, from: current, velocity: velocity)
            }
    }

    private func settle(expanded: Bool, from current: CGFloat, velocity: CGFloat) {
        let target = expanded ? expandedHeight : Self.collapsedHeight
        if isExpanded != expanded { isExpanded = expanded }
        withAnimation(SpringDetents.snapAnimation(from: current, to: target, velocity: velocity)) {
            liveHeight = target
        }
    }
}
