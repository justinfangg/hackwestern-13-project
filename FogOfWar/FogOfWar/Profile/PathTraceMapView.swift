import CoreLocation
import SwiftData
import SwiftUI
import FogKit

/// Profile path-tracing map (PRD P-2).
///
/// Draws every walked route segment from `ProfileModel.routeSegments` over the
/// explorer's cleared fog. Segments stay separate so GPS gaps are not joined.
struct PathTraceMapView: View {
    @Bindable private var explorationStore: ExplorationStore

    private let routeSegments: [[Coordinate]]
    private let tileMath: TileMath
    private let showsPlayer: Bool

    @State private var recenterToken = 0
    @State private var isFollowingUser = false

    init(
        explorationStore: ExplorationStore,
        routeSegments: [[Coordinate]],
        tileMath: TileMath = TileMath(),
        showsPlayer: Bool = false
    ) {
        self.explorationStore = explorationStore
        self.routeSegments = routeSegments
        self.tileMath = tileMath
        self.showsPlayer = showsPlayer
    }

    /// Convenience for Justin's `ProfileModel` (P-2 / FogKit README).
    init(
        explorationStore: ExplorationStore,
        profile: ProfileModel,
        tileMath: TileMath = TileMath(),
        showsPlayer: Bool = false
    ) {
        self.init(
            explorationStore: explorationStore,
            routeSegments: profile.routeSegments,
            tileMath: tileMath,
            showsPlayer: showsPlayer
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            FogMapView(
                clearedCells: explorationStore.clearedCells,
                latestChange: explorationStore.latestChange,
                tileMath: tileMath,
                userCoordinate: initialCenter,
                showsUserAnnotation: showsPlayer,
                routeSegments: routeSegments.map { $0.map(\.clCoordinate) },
                recenterToken: recenterToken,
                onMapTap: { _ in },
                onFollowingChanged: { isFollowingUser = $0 }
            )
            .ignoresSafeArea()

            Button {
                recenterToken &+= 1
            } label: {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.18))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .padding(16)
            .accessibilityLabel("Fit path on map")
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path tracing map")
        .accessibilityHint("Shows every route walked over cleared fog")
    }

    private var initialCenter: CLLocationCoordinate2D? {
        routeSegments.lazy.flatMap { $0 }.first?.clCoordinate
            ?? FogMapView.westernUniversity
    }
}

#Preview {
    let container = try! ModelContainer(
        for: ExploredCellRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = ExplorationStore(modelContainer: container)
    _ = store.clearTiles(around: [.westernCampus])
    let sample = ExpeditionSummary.sample
    return PathTraceMapView(
        explorationStore: store,
        routeSegments: sample.segments
    )
}
