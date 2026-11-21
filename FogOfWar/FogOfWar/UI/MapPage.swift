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
    @State private var showCamera = false

    private static let sheetBottomMargin: CGFloat = 23
    private static let sheetHorizontalMargin: CGFloat = 30.5

    var body: some View {
        map
            .frame(width: fullSize.width, height: fullSize.height)
            .offset(y: mapShift)
            .frame(width: fullSize.width, height: max(visibleHeight, 0))
            .overlay(alignment: .top) { topFade }
            .overlay(alignment: .bottom) { bottomChrome }
            .overlay(alignment: .topTrailing) { recenterButton }
            .overlay(alignment: .leading) {
                if services.debug.isSimulatorEnabled {
                    JoystickView(simulator: services.location.simulator)
                        .padding(.leading, 24)
                        .opacity(isQuestSheetExpanded ? 0 : chromeOpacity)
                        .allowsHitTesting(!isQuestSheetExpanded)
                        .animation(.smooth, value: isQuestSheetExpanded)
                }
            }
            .animation(.snappy, value: isFollowingUser)
            .sheet(isPresented: $showDebug) {
                NavigationStack {
                    DebugMenuView(settings: services.debug, location: services.location,
                                  onResetFog: services.resetFog)
                        .navigationTitle("Debug")
                }
            }
            .sheet(isPresented: $showCamera) { cameraSheet }
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
                services.location.simulator.boost = 5 // walking speed is hard to see while testing
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
        let chrome = chromeOpacity > 0.5
            ? Self.sheetBottomMargin + QuestSheet<EmptyView>.collapsedHeight + 6
            : 10
        let vertical = hiddenMapHeight + mapShift + chrome
        return UIEdgeInsets(top: vertical, left: 24, bottom: vertical, right: 24)
    }

    private var questMarkers: [QuestMarkerData] {
        guard let quest = services.quests.today else { return [] }
        let collected: Bool = if case .success = services.questCapture.state { true } else { false }
        return [
            QuestMarkerData(
                id: quest.id.uuidString,
                coordinate: quest.target.clCoordinate,
                title: quest.category.capitalized,
                subtitle: quest.title,
                participantCount: quest.foundTodayCount,
                status: collected ? .completed : .active
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

            QuestSheet(
                maxHeight: visibleHeight / 2 - Self.sheetBottomMargin,
                isExpanded: $isQuestSheetExpanded
            ) {
                QuestSheetContent(
                    onTakePhoto: takePhoto,
                    onShowDebug: { showDebug = true }
                )
            }
            .padding(.horizontal, Self.sheetHorizontalMargin)
            .padding(.bottom, Self.sheetBottomMargin)
            .opacity(chromeOpacity)
            .allowsHitTesting(chromeOpacity > 0.5)
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

    private func takePhoto() {
        #if targetEnvironment(simulator)
        // No camera in the Simulator: submit a generated test image.
        Task { await services.questCapture.capture(DevHarnessView.testImage()) }
        #else
        showCamera = true
        #endif
    }

    private var cameraSheet: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.session).ignoresSafeArea()
            Button {
                Task {
                    if let photo = try? await camera.capturePhoto() {
                        showCamera = false
                        camera.stop()
                        await services.questCapture.capture(photo)
                    }
                }
            } label: {
                Circle().fill(.white).frame(width: 72, height: 72)
            }
            .accessibilityLabel("Take photo")
            .padding(.bottom, 40)
        }
        .task { try? await camera.start() }
    }
}

/// Expanded body of the Quests sheet: today's quest, capture status and the
/// expedition controls.
private struct QuestSheetContent: View {
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
                    Label {
                        Text(quest.foundTodayCount, format: .number)
                    } icon: {
                        Image("QuestParticipants")
                            .renderingMode(.template)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(statusColor, in: .capsule)
                    .accessibilityLabel("\(quest.foundTodayCount) explorers")
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
        case .rejected, .error:
            Button("Retry") { capture.retry() }
                .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private var expeditionRow: some View {
        let expeditions = services.expeditions
        return HStack {
            if let active = expeditions.active {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(active.startedAt))
                    Text("\(Int(active.distanceMeters)) m · \(active.newTiles) tiles · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End", role: .destructive) { expeditions.end() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start expedition", systemImage: "figure.walk") { expeditions.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(SideQuestDesign.questCompleted)
                Spacer()
            }
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
        case .outOfAttempts: return "Out of attempts today"
        case .error(let message): return message
        }
    }
}
