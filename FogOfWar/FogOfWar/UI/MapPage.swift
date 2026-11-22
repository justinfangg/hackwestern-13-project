import CoreLocation
import SwiftUI
import FogKit

/// The map tab (Figma 55:3722): the cloud-covered map, the city name and
/// profile button on top, the locate button, Figma's top and bottom fades, and
/// the expandable Quests sheet sitting above the tab bar.
struct MapPage: View {
    let fullSize: CGSize
    let safeArea: EdgeInsets

    @Environment(FogServices.self) private var services
    @Environment(ExplorationStore.self) private var explorationStore
    @State private var permissions = LocationPermissions()
    @State private var camera = CameraController()
    @State private var tileMath = TileMath()
    @State private var recenterToken = 0
    @State private var isFollowingUser = true
    @State private var isQuestSheetExpanded = false
    @State private var showDebug = false
    @State private var showProfile = false
    /// Reverse-geocoded city for the name at the top of the map.
    @State private var coverage = CityCoverage()
    /// The active-quest card is showing its camera face.
    @State private var isCameraOpen = false

    /// The sheet sits 14 pt above the tab bar (Figma: 377 pt wide, bottom at 793 of 874).
    private static let sheetBottomMargin: CGFloat = MainTabBar.reservedHeight + 14
    private static let sheetHorizontalMargin: CGFloat = 12.5
    /// Top bar (city name + profile): 10 pt below the status bar.
    private static let topBarSpacing: CGFloat = 10
    private static let topBarHeight: CGFloat = 46
    private static let profileTrailingMargin: CGFloat = 23
    /// Locate button: 12 pt from the right edge, 13 pt above the sheet or card.
    private static let locateTrailingMargin: CGFloat = 12
    private static let locateSpacing: CGFloat = 13
    /// Active-quest card insets (Figma 16:383: 388 pt wide, 8 pt off the bottom).
    private static let questCardSideMargin: CGFloat = 7
    private static let questCardBottomMargin: CGFloat = 8

    /// A session (quest or free explore) is recording. Named for the quest
    /// layout it drives: full-screen map, tab bar hidden.
    private var isOnQuest: Bool { services.expeditions.active != nil }
    /// A free run from the Explore button is recording.
    private var isExploring: Bool { services.expeditions.active?.kind == .explore }

    var body: some View {
        map
            .frame(width: fullSize.width, height: fullSize.height)
            .overlay(alignment: .top) { topFade }
            // Debug joystick sits under the card/sheet so they cover it as they grow.
            .overlay(alignment: .leading) {
                if services.debug.isSimulatorEnabled {
                    JoystickView(simulator: services.location.simulator)
                        .padding(.leading, 24)
                        .opacity(isQuestSheetExpanded || isCameraOpen ? 0 : 1)
                        .allowsHitTesting(!isQuestSheetExpanded && !isCameraOpen)
                        .animation(.smooth, value: isCameraOpen)
                        .animation(.smooth, value: isQuestSheetExpanded)
                }
            }
            .overlay(alignment: .bottom) { bottomChrome }
            .overlay(alignment: .bottomTrailing) { locateButton }
            .overlay(alignment: .top) { topBar }
            .animation(.smooth, value: isCameraOpen)
            .animation(.smooth, value: isQuestSheetExpanded)
            .sheet(isPresented: $showProfile) {
                GeometryReader { proxy in
                    ProfilePage(contentHeight: proxy.size.height)
                }
                .presentationDragIndicator(.visible)
                .presentationBackground(SideQuestDesign.profileSurface)
            }
            .sheet(isPresented: $showDebug) {
                NavigationStack {
                    DebugMenuView(settings: services.debug, location: services.location,
                                  onResetFog: services.resetFog,
                                  userID: services.userID?.uuidString,
                                  onRestoreFog: { Task { await services.restoreFog() } })
                        .navigationTitle("Debug")
                }
            }
            .sheet(item: Binding(get: { services.expeditions.lastSummary },
                                 set: { if $0 == nil { services.expeditions.dismissSummary() } })) { summary in
                RecapSheet(summary: summary)
            }
            .task(id: coordinateKey) {
                guard let coordinate = playerCoordinate else { return }
                await coverage.locate(near: coordinate.clCoordinate)
            }
            .task {
                #if targetEnvironment(simulator)
                // No GPS in the iOS Simulator: start in Simulator Mode.
                if !services.debug.isMenuUnlocked {
                    services.debug.isMenuUnlocked = true
                    services.debug.isSimulatorEnabled = true
                }
                services.location.simulator.boost = SimulatedLocationProvider.debugBoost // walking speed is hard to see while testing
                #endif
                _ = await permissions.requestWhenInUse()
                services.start()
            }
    }

    // MARK: Map

    private var map: some View {
        FogMapView(
            clearedCells: explorationStore.clearedCells,
            latestChange: explorationStore.latestChange,
            tileMath: tileMath,
            userCoordinate: (services.location.displayCoordinate
                             ?? services.location.currentCoordinate)?.clCoordinate,
            questMarkers: questMarkers,
            routeSegments: activeRouteSegments,
            routeColor: UIColor(routeColor),
            mapChromeInsets: mapChromeInsets,
            recenterToken: recenterToken,
            onMapTap: { _ in },
            onFollowingChanged: { isFollowingUser = $0 },
            onQuestSelected: { _ in isQuestSheetExpanded = true }
        )
    }

    /// Lifts MapKit's legal label above the Quests pill. MapKit centers the
    /// player inside these margins, so top and bottom stay equal to keep the
    /// dot at the map view's center.
    private var mapChromeInsets: UIEdgeInsets {
        let vertical = bottomChromeHeight + 6
        return UIEdgeInsets(top: vertical, left: 24, bottom: vertical, right: 24)
    }

    /// Height of the collapsed sheet (or the quest card) plus its margin.
    private var bottomChromeHeight: CGFloat {
        isOnQuest
            ? Self.questCardBottomMargin + ActiveQuestCard.height
            : Self.sheetBottomMargin + QuestSheet<EmptyView>.collapsedHeight
    }

    private var cityName: String? {
        services.debug.cityName(real: coverage.city?.name)
    }

    private var playerCoordinate: Coordinate? {
        services.location.currentCoordinate ?? services.location.displayCoordinate
    }

    /// Changes only when the player moves ~1 km, so the city lookup isn't re-run on every fix.
    private var coordinateKey: String? {
        playerCoordinate.map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) }
    }

    private var questStatus: QuestMarkerData.Status {
        switch services.questCapture.state {
        case .success, .alreadyCompleted: return .completed
        default: return .active
        }
    }

    private var routeColor: Color {
        if isExploring { return SideQuestDesign.accentGreen }
        return questStatus == .completed ? SideQuestDesign.questCompleted : SideQuestDesign.questActive
    }

    private var questMarkers: [QuestMarkerData] {
        guard let quest = services.quests.today else { return [] }
        return [
            QuestMarkerData(
                id: quest.id.uuidString,
                coordinate: quest.target.clCoordinate,
                title: quest.category.capitalized,
                subtitle: quest.title,
                participantCount: services.debug.participantCount(real: quest.foundTodayCount),
                status: questStatus,
                // The accepted-quest frame shows only the beacon.
                showsLabel: !isOnQuest || isExploring
            )
        ]
    }

    private var activeRouteSegments: [[CLLocationCoordinate2D]] {
        guard let segments = services.expeditions.active?.segments else { return [] }
        return segments.map { $0.map(\.clCoordinate) }
    }

    // MARK: Chrome

    /// Figma "StatusBarBg": a faint wash keeping the status bar legible.
    private var topFade: some View {
        LinearGradient(
            colors: [Color(white: 217 / 255, opacity: 0.26), Color(white: 217 / 255, opacity: 0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 47)
        .allowsHitTesting(false)
    }

    /// Figma bottom "StatusBarBg": solid #EBEBEB at the edge fading upward.
    private func bottomFade(height: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: SideQuestDesign.mapBottomFade.opacity(0), location: 0),
                .init(color: Color(red: 233 / 255, green: 233 / 255, blue: 233 / 255, opacity: 0.42), location: 0.322),
                .init(color: SideQuestDesign.mapBottomFade, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }

    /// City name centered, profile button on the right (Figma "Location
    /// Selector" and "Profile", 10 pt under the status bar).
    private var topBar: some View {
        ZStack {
            Text(cityName ?? "Locating…")
                .font(SideQuestDesign.ptSans(fixed: 20))
                .tracking(-0.6)
                .foregroundStyle(cityName == nil ? SideQuestDesign.boardLabelText : SideQuestDesign.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(minWidth: 119)
                .frame(height: Self.topBarHeight)
                .background(.white, in: Capsule())
                .frame(maxWidth: fullSize.width - 2 * (Self.profileTrailingMargin + Self.topBarHeight + 8))
                .accessibilityLabel(cityName.map { "Exploring \($0)" } ?? "Finding your city")
                .animation(.smooth, value: cityName)

            Button { showProfile = true } label: {
                Image("ProfileAvatar")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .frame(width: Self.topBarHeight, height: Self.topBarHeight)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Self.profileTrailingMargin)
        }
        .padding(.top, safeArea.top + Self.topBarSpacing)
        .opacity(isCameraOpen ? 0 : 1)
        .allowsHitTesting(!isCameraOpen)
    }

    private var bottomChrome: some View {
        ZStack(alignment: .bottom) {
            // Figma stacks two of these: a tall soft one and a short one at the edge.
            bottomFade(height: 111)
            bottomFade(height: 51)

            if let expedition = services.expeditions.active, expedition.kind == .explore {
                ActiveExploreCard(
                    startedAt: expedition.startedAt,
                    distanceMeters: expedition.distanceMeters,
                    newTiles: expedition.newTiles,
                    onEnd: endSession
                )
                .padding(.horizontal, Self.questCardSideMargin)
                .padding(.bottom, Self.questCardBottomMargin)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isOnQuest, let quest = services.quests.today, let expedition = services.expeditions.active {
                ActiveQuestCard(
                    quest: quest,
                    startedAt: expedition.startedAt,
                    captureState: services.questCapture.state,
                    distanceToTarget: services.questCapture.distanceToTarget,
                    participantCount: services.debug.participantCount(real: quest.foundTodayCount),
                    isCameraOpen: $isCameraOpen,
                    camera: camera,
                    cameraHeight: cameraCardHeight,
                    onAbandon: abandonQuest,
                    onCapture: captureFromCard,
                    onPhoto: submitPhoto
                )
                .padding(.horizontal, Self.questCardSideMargin)
                .padding(.bottom, Self.questCardBottomMargin)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                QuestSheet(
                    maxHeight: fullSize.height / 2 - Self.sheetBottomMargin,
                    isExpanded: $isQuestSheetExpanded,
                    onExplore: startExploring
                ) {
                    QuestSheetContent(
                        onAccept: acceptQuest,
                        onTakePhoto: takePhoto,
                        onShowDebug: { showDebug = true }
                    )
                }
                .padding(.horizontal, Self.sheetHorizontalMargin)
                .padding(.bottom, Self.sheetBottomMargin)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Quest lifecycle

    /// Accepting a quest starts recording the route; the layout reacts to
    /// `isOnQuest` (MainView expands the map to full screen).
    private func acceptQuest() {
        withAnimation(MainView.questTransition) {
            isQuestSheetExpanded = false
            services.expeditions.start(kind: .quest)
        }
        recenterToken &+= 1
    }

    /// Explore button: a free run with no target. Records time, distance,
    /// route and new tiles like a quest session, and ends with the recap.
    private func startExploring() {
        withAnimation(MainView.questTransition) {
            isQuestSheetExpanded = false
            services.expeditions.start(kind: .explore)
        }
        recenterToken &+= 1
    }

    private func endSession() {
        withAnimation(MainView.questTransition) {
            services.expeditions.end()
        }
    }

    /// The card's capture button doubles as "try again" after a failed photo.
    private func captureFromCard() {
        let capture = services.questCapture
        switch capture.state {
        case .rejected, .tooFar, .error:
            capture.retry()
            if case .ready = capture.state { takePhoto() }
        default:
            takePhoto()
        }
    }

    private func abandonQuest() {
        withAnimation(MainView.questTransition) {
            isCameraOpen = false
            services.expeditions.end()
        }
    }

    /// Figma "Add Location": jumps back to the player and resumes following.
    private var locateButton: some View {
        let isHidden = isQuestSheetExpanded || isCameraOpen
        return Button {
            recenterToken &+= 1
        } label: {
            Image("MapLocate")
                .frame(width: 46, height: 46)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Center on my location")
        .accessibilityValue(isFollowingUser ? "Following" : "Not following")
        .padding(.trailing, Self.locateTrailingMargin)
        .padding(.bottom, bottomChromeHeight + Self.locateSpacing)
        .opacity(isHidden ? 0 : 1)
        .scaleEffect(isHidden ? 0.6 : 1)
        .allowsHitTesting(!isHidden)
        .animation(MainView.questTransition, value: isOnQuest)
    }

    // MARK: Quest capture

    /// Opens the camera inside the active-quest card (accepting the quest
    /// first if the photo was started from the Quests sheet).
    private func takePhoto() {
        if !isOnQuest { acceptQuest() }
        withAnimation(ActiveQuestCard.cameraTransition) { isCameraOpen = true }
    }

    /// Shrinks the card back to its summary, then verifies the photo; the
    /// result shows up in the card's status line.
    private func submitPhoto(_ photo: CGImage) {
        withAnimation(ActiveQuestCard.cameraTransition) { isCameraOpen = false }
        Task { await services.questCapture.capture(photo) }
    }

    /// Figma's 542 pt camera card, kept clear of the status bar on short screens.
    private var cameraCardHeight: CGFloat {
        min(ActiveQuestCard.cameraHeight, fullSize.height - safeArea.top - Self.questCardBottomMargin - 16)
    }
}

/// Expanded body of the Quests sheet: today's quest, capture status and the
/// button that accepts it.
private struct QuestSheetContent: View {
    let onAccept: () -> Void
    let onTakePhoto: () -> Void
    let onShowDebug: () -> Void

    @Environment(FogServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            questCard
            Spacer(minLength: 0)
            expeditionRow
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var questCard: some View {
        if let quest = services.quests.today {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(quest.title)
                        .font(SideQuestDesign.ptSans(24, relativeTo: .title2))
                        .foregroundStyle(SideQuestDesign.primaryText)
                    Spacer()
                    let participants = services.debug.participantCount(real: quest.foundTodayCount)
                    Label {
                        Text(participants, format: .number)
                    } icon: {
                        Image("QuestParticipants")
                            .renderingMode(.template)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(statusColor, in: .capsule)
                    .accessibilityLabel("\(participants) explorers")
                }
                Text(quest.hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    captureAction
                }
            }
        } else {
            Text(services.quests.isLoading ? "Loading today's quest…" : "No quest nearby today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var captureAction: some View {
        let capture = services.questCapture
        switch capture.state {
        case .ready:
            Button("Take photo", systemImage: "camera.fill", action: onTakePhoto)
                .buttonStyle(.borderedProminent)
                .tint(SideQuestDesign.questActive)
        case .rejected, .error, .tooFar:
            Button("Retry") { capture.retry() }
                .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    /// The sheet is only on screen before a quest is accepted; once accepted
    /// the active-quest card takes over (see `MapPage.bottomChrome`).
    private var expeditionRow: some View {
        HStack {
            Button("Accept quest", systemImage: "figure.walk", action: onAccept)
                .buttonStyle(.borderedProminent)
                .tint(SideQuestDesign.questCompleted)
                .disabled(services.quests.today == nil)
            Spacer()
            #if DEBUG
            Button("Debug", systemImage: "ladybug", action: onShowDebug)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            #endif
        }
        .controlSize(.small)
    }

    private var statusColor: Color {
        if case .success = services.questCapture.state { return SideQuestDesign.questCompleted }
        return SideQuestDesign.questActive
    }

    private var statusText: String {
        let capture = services.questCapture
        switch capture.state {
        case .noQuest: return "No quest loaded"
        case .locked:
            if let distance = capture.distanceToTarget {
                return "\(Int(distance)) m away · get within 40 m"
            }
            return "Get within 40 m to unlock"
        case .ready: return "You're here, snap it!"
        case .verifying: return "Verifying…"
        case .success(let sticker): return "Collected \(sticker.category) sticker"
        case .rejected(let reason, let left): return "Not verified: \(reason) (\(left) left)"
        case .tooFar(let distance): return "Photo was \(Int(distance)) m away, get closer"
        case .alreadyCompleted: return "Already found today"
        case .outOfAttempts: return "Out of attempts today"
        case .error(let message): return message
        }
    }
}
