import SwiftUI
import FogKit

/// Dark card shown during a free run (Explore button): no target, just the
/// session so far. Elapsed time, distance and new tiles, plus an End button.
/// Same size and shape as `ActiveQuestCard` so the map layout doesn't move.
struct ActiveExploreCard: View {
    let startedAt: Date
    let distanceMeters: Double
    let newTiles: Int
    let onEnd: () -> Void

    @State private var confirmEnd = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                    .font(SideQuestDesign.calSans(65, relativeTo: nil))
                    .tracking(-0.65)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 16)
                    .accessibilityLabel("Time exploring")

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Free explore")
                    Text(statsLine)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                }
                .font(SideQuestDesign.ptSans(20))
                .tracking(-0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 26)
            }
            .padding(.leading, 32)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 5) {
                    Image("ExplorePlay")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                    Text("Exploring")
                        .font(SideQuestDesign.ptSans(fixed: 15))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(SideQuestDesign.accentGreen, in: Capsule())
                .padding(.top, 30)
                .accessibilityHidden(true)

                Spacer(minLength: 0)

                Button { confirmEnd = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("End")
                            .font(SideQuestDesign.ptSans(fixed: 20))
                            .tracking(-0.6)
                    }
                    .foregroundStyle(SideQuestDesign.primaryText)
                    .frame(width: 96, height: 46.6)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End exploring")
                .padding(.bottom, 21.4)
            }
            .padding(.trailing, 27)
        }
        .foregroundStyle(SideQuestDesign.pillText)
        .frame(maxWidth: .infinity)
        .frame(height: ActiveQuestCard.height)
        .background(SideQuestDesign.canvas)
        .clipShape(RoundedRectangle(cornerRadius: ActiveQuestCard.cornerRadius, style: .continuous))
        .animation(.snappy, value: newTiles)
        .confirmationDialog("End this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End Session", action: onEnd)
        } message: {
            Text("Your time, distance and route are saved.")
        }
    }

    private var statsLine: String {
        let tiles = newTiles == 1 ? "1 new tile" : "\(newTiles.formatted()) new tiles"
        return "\(ProfilePage.distanceText(distanceMeters)) · \(tiles)"
    }
}

#Preview {
    ActiveExploreCard(startedAt: .now.addingTimeInterval(-754), distanceMeters: 1_240, newTiles: 84, onEnd: {})
        .padding(7)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(.gray)
}
