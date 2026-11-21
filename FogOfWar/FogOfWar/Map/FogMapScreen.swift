import CoreLocation
import SwiftUI

/// Production composition for the map module. Teammates can pass accepted location fixes and
/// quest marker data without the map taking ownership of either pipeline.
struct FogMapScreen: View {
    @Bindable private var explorationStore: ExplorationStore

    private let tileMath: TileMath
    private let userCoordinate: CLLocationCoordinate2D?
    private let questMarker: QuestMarkerData?
    private let showsDebugHUD: Bool
    private let showsQuestCard: Bool

    @State private var recenterToken = 0
    @State private var isFollowingUser = true
    @State private var lastTappedCoordinate: CLLocationCoordinate2D
    @State private var isResetConfirmationPresented = false

    init(
        explorationStore: ExplorationStore,
        tileMath: TileMath = TileMath(),
        userCoordinate: CLLocationCoordinate2D? = nil,
        questMarker: QuestMarkerData? = nil,
        showsDebugHUD: Bool = true,
        showsQuestCard: Bool = true
    ) {
        self.explorationStore = explorationStore
        self.tileMath = tileMath
        self.userCoordinate = userCoordinate
        self.questMarker = questMarker
        self.showsDebugHUD = showsDebugHUD
        self.showsQuestCard = showsQuestCard
        _lastTappedCoordinate = State(initialValue: questMarker?.coordinate ?? FogMapView.westernUniversity)
    }

    var body: some View {
        ZStack {
            FogMapView(
                clearedCells: explorationStore.clearedCells,
                latestChange: explorationStore.latestChange,
                tileMath: tileMath,
                userCoordinate: userCoordinate,
                questMarker: questMarker,
                recenterToken: recenterToken,
                onMapTap: handleMapTap,
                onFollowingChanged: { isFollowingUser = $0 }
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [Color(red: 0.025, green: 0.05, blue: 0.10).opacity(0.82), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 170)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                if showsQuestCard, let questMarker {
                    questCard(for: questMarker)
                }

                Spacer()

                HStack(alignment: .bottom, spacing: 12) {
                    #if DEBUG
                    if showsDebugHUD {
                        MapDebugHUD(
                            discoveredCount: explorationStore.clearedCells.count,
                            lastTappedCoordinate: lastTappedCoordinate,
                            onAreaReveal: triggerDebugAreaReveal,
                            onReset: { isResetConfirmationPresented = true }
                        )
                    }
                    #endif

                    Spacer(minLength: 0)

                    Button {
                        recenterToken &+= 1
                    } label: {
                        Image(systemName: isFollowingUser ? "location.fill" : "location")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color(red: 0.30, green: 0.96, blue: 0.88))
                            .frame(width: 50, height: 50)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.20), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
                    }
                    .accessibilityLabel("Recenter map")
                    .accessibilityHint("Returns the map to the explorer location")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Reset all explored territory?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reset Exploration", role: .destructive) {
                explorationStore.resetExploration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the locally saved cells on this device.")
        }
    }

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        lastTappedCoordinate = coordinate
        #if DEBUG
        explorationStore.reveal(
            at: coordinate,
            radiusMeters: ExplorationStore.visionRadiusMeters,
            source: .debugTap
        )
        #endif
    }

    private func triggerDebugAreaReveal() {
        explorationStore.reveal(
            at: lastTappedCoordinate,
            radiusMeters: 150,
            source: .debugTap
        )
    }

    @ViewBuilder
    private func questCard(for quest: QuestMarkerData) -> some View {
        HStack(spacing: 12) {
            Image(systemName: quest.systemImageName)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color(red: 0.34, green: 0.96, blue: 0.86))
                .frame(width: 42, height: 42)
                .background(Color(red: 0.03, green: 0.18, blue: 0.20), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("DAILY SIDE QUEST")
                    .font(.caption2.weight(.black))
                    .tracking(1.4)
                    .foregroundStyle(Color(red: 0.36, green: 0.94, blue: 0.85))
                Text(quest.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = quest.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily side quest, \(quest.title)")
    }
}
