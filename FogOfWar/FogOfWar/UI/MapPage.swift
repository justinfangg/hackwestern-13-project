import CoreLocation
import SwiftUI
import FogKit

/// Contents of the map container: the cloud-covered map, Figma's top and
/// bottom fades, and the expandable Quests sheet.
///
/// The map view itself stays full-screen size and is centered in whatever
/// height the split gives it, so resizing the container only clips (no MapKit
/// relayout) and the player's dot stays in the middle of the visible area.
struct MapPage: View {
    let visibleHeight: CGFloat
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
    /// The active-quest card is showing its camera face.
    @State private var isCameraOpen = false

    private static let sheetBottomMargin: CGFloat = 23
    private static let sheetHorizontalMargin: CGFloat = 30.5
    /// Active-quest card insets (Figma 16:383: 388 pt wide, 8 pt off the bottom).
    private static let questCardSideMargin: CGFloat = 7
    private static let questCardBottomMargin: CGFloat = 8

    /// A quest is "accepted" while its expedition is recording.
    private var isOnQuest: Bool { services.expeditions.active != nil }

    var body: some View {
        map
            .frame(width: fullSize.width, height: fullSize.height)
            .offset(y: mapShift)
            .frame(width: fullSize.width, height: max(visibleHeight, 0))
            .overlay(alignment: .top) { topFade }
            // Debug joystick sits under the card/sheet so they cover it as they grow.
            .overlay(alignment: .leading) {
                if services.debug.isSimulatorEnabled {
                    JoystickView(simulator: services.location.simulator)
                        .padding(.leading, 24)
                        .opacity(isQuestSheetExpanded || isCameraOpen ? 0 : chromeOpacity)
                        .allowsHitTesting(!isQuestSheetExpanded && !isCameraOpen)
                        .animation(.smooth, value: isCameraOpen)
                        .animation(.smooth, value: isQuestSheetExpanded)
                }
            }
            .overlay(alignment: .bottom) { bottomChrome }
            .overlay(alignment: .topTrailing) { recenterButton }
            .animation(.snappy, value: isFollowingUser)
            .sheet(isPresented: $showDebug) {
                NavigationStack {
                    DebugMenuView(settings: services.debug, location: services.location,
                                  onResetFog: services.resetFog)
                        .navigationTitle("Debug")
                }
            }
            .sheet(item: Binding(get: { services.expeditions.lastSummary },
                                 set: { if $0 == nil { services.expeditions.dismissSummary() } })) { summary in
                RecapSheet(summary: summary)
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

    private var hiddenMapHeight: CGFloat { max(fullSize.height - visibleHeight, 0) / 2 }

    /// As the map collapses toward a strip, nudge its center below the status
    /// bar so the player's dot never hides behind the Dynamic Island.
    private var mapShift: CGFloat {
        let expanded = fullSize.height - 88   // Figma map height (874 → 786)
        let collapsed = safeArea.top + 118    // MainView's profile detent
        guard expanded > collapsed else { return 0 }
        let progress = min(max((expanded - visibleHeight) / (expanded - collapsed), 0), 1)
        return safeArea.top / 2 * progress
    }

    /// Fades the Quests sheet and joystick out as the profile takes over.
    private var chromeOpacity: Double {
        Double(min(max((visibleHeight - 250) / 110, 0), 1))
    }

    private var map: some View {
        FogMapView(
            clearedCells: explorationStore.clearedCells,
            latestChange: explorationStore.latestChange,
            tileMath: tileMath,
            userCoordinate: (services.location.displayCoordinate
                             ?? services.location.currentCoordinate)?.clCoordinate,
            questMarkers: questMarkers,
            routeSegments: activeRouteSegments,
            routeColor: UIColor(questStatus == .completed ? SideQuestDesign.questCompleted : SideQuestDesign.questActive),
            mapChromeInsets: mapChromeInsets,
            recenterToken: recenterToken,
            onMapTap: { _ in },
            onFollowingChanged: { isFollowingUser = $0 },
            onQuestSelected: { _ in isQuestSheetExpanded = true }
        )
    }

    /// Lifts MapKit's legal label above the Quests pill. MapKit centers the
    /// player inside these margins, so top and bottom stay equal to keep the
    /// dot at the map view's center (the visible center, plus `mapShift`).
    private var mapChromeInsets: UIEdgeInsets {
        let chrome: CGFloat = if isOnQuest {
            Self.questCardBottomMargin + ActiveQuestCard.height + 6
        } else if chromeOpacity > 0.5 {
            Self.sheetBottomMargin + QuestSheet<EmptyView>.collapsedHeight + 6
        } else {
            10
        }
        let vertical = hiddenMapHeight + mapShift + chrome
        return UIEdgeInsets(top: vertical, left: 24, bottom: vertical, right: 24)
    }

    private var questStatus: QuestMarkerData.Status {
        switch services.questCapture.state {
        case .success, .alreadyCompleted: return .completed
        default: return .active
        }
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
                showsLabel: !isOnQuest
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

    private var bottomChrome: some View {
        ZStack(alignment: .bottom) {
            // Figma bottom "StatusBarBg": solid #EBEBEB at the edge fading upward.
            LinearGradient(
                stops: [
                    .init(color: SideQuestDesign.mapBottomFade.opacity(0), location: 0),
                    .init(color: Color(red: 233 / 255, green: 233 / 255, blue: 233 / 255, opacity: 0.42), location: 0.322),
                    .init(color: SideQuestDesign.mapBottomFade, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 46)
            .allowsHitTesting(false)

            if isOnQuest, let quest = services.quests.today, let expedition = services.expeditions.active {
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
                    maxHeight: visibleHeight / 2 - Self.sheetBottomMargin,
                    isExpanded: $isQuestSheetExpanded
                ) {
                    QuestSheetContent(
                        onAccept: acceptQuest,
                        onTakePhoto: takePhoto,
                        onShowDebug: { showDebug = true }
                    )
                }
                .padding(.horizontal, Self.sheetHorizontalMargin)
                .padding(.bottom, Self.sheetBottomMargin)
                .opacity(chromeOpacity)
                .allowsHitTesting(chromeOpacity > 0.5)
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
            services.expeditions.start()
        }
        recenterToken &+= 1
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

    @ViewBuilder
    private var recenterButton: some View {
        if !isFollowingUser {
            Button {
                recenterToken &+= 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0x0C / 255, green: 0x79 / 255, blue: 0xFE / 255))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center on my location")
            .padding(.top, safeArea.top + 8)
            .padding(.trailing, 16)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
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
        min(ActiveQuestCard.cameraHeight, visibleHeight - safeArea.top - Self.questCardBottomMargin - 16)
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
