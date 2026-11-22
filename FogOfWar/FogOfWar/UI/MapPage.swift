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
    /// The photo being checked; the card shows it (and the answer) instead of the camera.
    @State private var questPhoto: QuestPhoto?
    /// The card has grown to the top of the screen to show the answer.
    @State private var isResultExpanded = false
    /// Set when a quest is opened in the sheet: the map zooms to its target.
    @State private var questFocus: MapFocus?

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
            focus: questFocus,
            onMapTap: { _ in },
            onFollowingChanged: { isFollowingUser = $0 },
            onQuestSelected: { id in
                // Tapping a beacon picks that quest (outlined in the sheet) unless one is under way.
                if !isOnQuest, let uuid = UUID(uuidString: id) { services.selectQuest(uuid) }
                isQuestSheetExpanded = true
            }
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
        let selectedID = services.quests.selectedID
        // On a quest only its beacon shows; otherwise every quest in the area.
        let shown = services.quests.options.filter { !isOnQuest || isExploring || $0.id == selectedID }
        return shown.map { option in
            let quest = option.quest
            return QuestMarkerData(
                id: quest.id.uuidString,
                coordinate: quest.target.clCoordinate,
                title: quest.category.capitalized,
                subtitle: quest.title,
                participantCount: services.debug.participantCount(real: quest.foundTodayCount),
                status: option.id == selectedID ? questStatus : (option.completedByMe ? .completed : .active),
                // The accepted-quest frame shows only the beacon.
                showsLabel: !isOnQuest || isExploring
            )
        }
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

            #if DEBUG
            // Mirrors the profile button on the left.
            Button { showDebug = true } label: {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SideQuestDesign.primaryText)
                    .frame(width: Self.topBarHeight, height: Self.topBarHeight)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Debug menu")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.profileTrailingMargin)
            #endif
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
                .withLocateButton(locateButton, spacing: Self.locateSpacing)
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
                    onPhoto: submitPhoto,
                    debugPhoto: debugPhoto,
                    resultFace: questPhoto.map { resultFace(for: $0, quest: quest) },
                    resultHeight: isResultExpanded ? resultCardHeight : cameraCardHeight
                )
                .padding(.horizontal, Self.questCardSideMargin)
                .withLocateButton(locateButton, spacing: Self.locateSpacing)
                .padding(.bottom, Self.questCardBottomMargin)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                QuestSheet(
                    maxHeight: fullSize.height / 2 - Self.sheetBottomMargin,
                    isExpanded: $isQuestSheetExpanded,
                    onExplore: startExploring
                ) {
                    QuestSheetContent(
                        onOpen: openQuest,
                        onAccept: { services.selectQuest($0); acceptQuest() },
                        onTakePhoto: { services.selectQuest($0); takePhoto() }
                    )
                }
                .padding(.horizontal, Self.sheetHorizontalMargin)
                // Rides on top of the sheet as it opens (or is dragged).
                .withLocateButton(locateButton, spacing: Self.locateSpacing)
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

    /// A quest opened in the sheet: make it the selected one and zoom the map
    /// to its target, in the part of the map the expanded sheet leaves visible.
    private func openQuest(_ quest: Quest) {
        services.selectQuest(quest.id)
        questFocus = MapFocus(
            coordinate: quest.target.clCoordinate,
            padding: UIEdgeInsets(
                top: safeArea.top + Self.topBarSpacing + Self.topBarHeight + 16,
                left: 24,
                bottom: fullSize.height / 2 + 16,
                right: 24
            )
        )
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
        if debugPhoto != nil {
            takePhoto()
            return
        }
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
            questPhoto = nil
            isResultExpanded = false
            services.expeditions.end()
        }
    }

    /// Figma "Add Location": jumps back to the player and resumes following.
    /// Sits just above the Quests sheet or the active card and moves with it.
    private var locateButton: some View {
        let isHidden = isCameraOpen
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

    /// Freezes the shot on the card; `QuestResultView` sends it to be verified
    /// and plays the answer. The camera stays "open" (top bar hidden, card tall).
    private func submitPhoto(_ photo: CGImage) {
        isResultExpanded = false
        withAnimation(ActiveQuestCard.cameraTransition) { questPhoto = QuestPhoto(image: photo) }
    }

    private func resultFace(for photo: QuestPhoto, quest: Quest) -> AnyView {
        AnyView(
            QuestResultView(
                photo: photo.image,
                quest: quest,
                capture: services.questCapture,
                isExpanded: $isResultExpanded,
                submit: { await services.questCapture.capture(photo.image) },
                expedition: expeditionSnapshot,
                onRetry: retryPhoto,
                onClose: closeResult,
                onFinish: finishQuest
            )
            .id(photo.id)
        )
    }

    /// "Try again": the card shrinks back to the camera (or to its summary if
    /// the player has walked out of range).
    private func retryPhoto() {
        let capture = services.questCapture
        capture.retry()
        let canShoot = debugPhoto != nil || capture.canCapture
        withAnimation(ActiveQuestCard.cameraTransition) {
            isResultExpanded = false
            questPhoto = nil
            isCameraOpen = canShoot
        }
    }

    private func closeResult() {
        withAnimation(ActiveQuestCard.cameraTransition) {
            isResultExpanded = false
            questPhoto = nil
            isCameraOpen = false
        }
    }

    /// The sticker stats were closed: the quest is over. The stats already
    /// showed the walk, so the recap sheet is skipped.
    private func finishQuest() {
        withAnimation(MainView.questTransition) {
            isResultExpanded = false
            questPhoto = nil
            isCameraOpen = false
            services.expeditions.end()
        }
        services.expeditions.dismissSummary()
    }

    /// The quest's walk so far, as the sticker stats show it.
    private func expeditionSnapshot() -> ExpeditionSummary? {
        guard let active = services.expeditions.active else { return nil }
        return ExpeditionSummary(
            id: active.id,
            kind: active.kind,
            startedAt: active.startedAt,
            endedAt: .now,
            distanceMeters: active.distanceMeters,
            newTiles: active.newTiles,
            segments: active.segments.filter { !$0.isEmpty },
            sticker: active.sticker
        )
    }

    /// Debug bypass photo source; always nil in release builds.
    private var debugPhoto: (() -> CGImage?)? {
        #if DEBUG
        services.debug.isQuestCameraBypassActive ? { DebugQuestPhoto.random() } : nil
        #else
        nil
        #endif
    }

    /// The card with the verification answer: up to just under the status bar.
    private var resultCardHeight: CGFloat {
        fullSize.height - safeArea.top - 6 - Self.questCardBottomMargin
    }

    /// Figma's 542 pt camera card, kept clear of the status bar on short screens.
    private var cameraCardHeight: CGFloat {
        min(ActiveQuestCard.cameraHeight, fullSize.height - safeArea.top - Self.questCardBottomMargin - 16)
    }
}

/// Expanded body of the Quests sheet: every quest in the area today as a
/// compact row (what to find, how far, how many found it). Tapping a row opens
/// it to show the hint and its own Accept button, and zooms the map to it.
private struct QuestSheetContent: View {
    let onOpen: (Quest) -> Void
    let onAccept: (UUID) -> Void
    let onTakePhoto: (UUID) -> Void

    @Environment(FogServices.self) private var services
    /// The row showing its details (one at a time).
    @State private var openID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if services.quests.options.isEmpty {
                Text(services.quests.isLoading ? "Loading today's quests…" : "No quests nearby today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(services.quests.options) { option in
                            QuestOptionRow(
                                option: option,
                                isOpen: option.id == openID,
                                onToggle: { toggle(option) },
                                onAccept: { onAccept(option.id) },
                                onTakePhoto: { onTakePhoto(option.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
        // A beacon tapped on the map opens that quest's row.
        .onChange(of: services.quests.selectedID) { _, id in
            if openID != nil, let id { openID = id }
        }
    }

    private func toggle(_ option: QuestOption) {
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
            openID = openID == option.id ? nil : option.id
        }
        if openID == option.id { onOpen(option.quest) }
    }
}

/// One quest in the sheet. Closed: icon, title, distance, finds today (tap to open).
/// Open: adds the hint, the capture status and the quest's own action button.
private struct QuestOptionRow: View {
    let option: QuestOption
    let isOpen: Bool
    let onToggle: () -> Void
    let onAccept: () -> Void
    let onTakePhoto: () -> Void

    @Environment(FogServices.self) private var services

    private var quest: Quest { option.quest }
    private var isSelected: Bool { option.id == services.quests.selectedID }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) { summary }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? "Hides the details" : "Shows the details and zooms the map to it")
                .accessibilityAddTraits(isOpen ? .isSelected : [])

            if isOpen {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isOpen ? SideQuestDesign.questActive : SideQuestDesign.boardBorder, lineWidth: isOpen ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: QuestCategory.symbolName(quest.category))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tint))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(quest.title)
                    .font(SideQuestDesign.ptSans(20, relativeTo: .title3))
                    .tracking(-0.6)
                    .foregroundStyle(SideQuestDesign.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Label {
                Text(participants, format: .number)
            } icon: {
                Image("QuestParticipants").renderingMode(.template)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(tint, in: .capsule)
            .accessibilityLabel("\(participants) explorers")
        }
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(quest.hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let status = statusText {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                action
            }
        }
    }

    private var tint: Color { option.completedByMe ? SideQuestDesign.questCompleted : SideQuestDesign.questActive }

    private var participants: Int { services.debug.participantCount(real: quest.foundTodayCount) }

    /// "80m away" (the collapsed row's second line).
    private var subtitle: String {
        if option.completedByMe { return "Found today" }
        guard let here = services.location.currentCoordinate ?? services.location.displayCoordinate else {
            return "Locating…"
        }
        return QuestDistance.text(Geo.distance(here, quest.target)) + " away"
    }

    private var isReadyHere: Bool {
        guard isSelected, case .ready = services.questCapture.state else { return false }
        return true
    }

    /// Debug camera bypass: the camera is allowed from anywhere on the selected quest.
    private var isBypassReady: Bool {
        #if DEBUG
        isSelected && services.debug.isQuestCameraBypassActive && services.questCapture.canCapture
        #else
        false
        #endif
    }

    @ViewBuilder
    private var action: some View {
        if option.completedByMe {
            Label("Found", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SideQuestDesign.questCompleted)
        } else if option.attemptsLeft <= 0 {
            EmptyView()
        } else if isReadyHere || isBypassReady {
            Button("Take photo", systemImage: "camera.fill", action: onTakePhoto)
                .buttonStyle(.borderedProminent)
                .tint(SideQuestDesign.questActive)
                .controlSize(.small)
                .accessibilityLabel("Take photo for \(quest.title)")
        } else {
            Button("Accept", systemImage: "figure.walk", action: onAccept)
                .buttonStyle(.borderedProminent)
                .tint(SideQuestDesign.questCompleted)
                .controlSize(.small)
                .accessibilityLabel("Accept \(quest.title)")
        }
    }

    /// Only when there's something beyond the distance to say.
    private var statusText: String? {
        if option.completedByMe { return nil }
        if option.attemptsLeft <= 0 { return "Out of attempts today" }
        guard isSelected else { return "Get within \(Int(quest.geofenceRadiusM))m to take the photo" }
        switch services.questCapture.state {
        case .ready: return "You're here, snap it!"
        case .verifying: return "Verifying…"
        case .rejected(let reason, let left): return "Not verified: \(reason) (\(left) left)"
        case .tooFar(let distance): return "Photo was \(Int(distance))m away, get closer"
        case .error(let message): return message
        default: return "Get within \(Int(quest.geofenceRadiusM))m to take the photo"
        }
    }
}

/// "80m", "450m", "1.2km": rounded so the row doesn't flicker on every GPS fix.
enum QuestDistance {
    static func text(_ meters: Double) -> String {
        let m = max(meters, 0)
        if m < 1_000 { return "\(Int((m / 10).rounded()) * 10)m" }
        return (m / 1_000).formatted(.number.precision(.fractionLength(1))) + "km"
    }
}

private extension View {
    /// Stacks `button` above this view, right-aligned to the screen edge, so it
    /// follows the view's top edge as it grows.
    func withLocateButton(_ button: some View, spacing: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: spacing) {
            button
            self
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
