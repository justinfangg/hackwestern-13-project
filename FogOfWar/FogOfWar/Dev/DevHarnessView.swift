//
//  DevHarnessView.swift
//  FogOfWar
//
//  TEMPORARY developer test screen (Justin). Exercises FogKit end to end.
//  Map visualization now uses Ayman's atmospheric FogMapView + ExplorationStore
//  instead of the temporary square-grid blue dots. Delete the Dev/ folder once
//  Jonathan's designed screens cover this flow.
//

import CoreLocation
import SwiftUI
import FogKit

struct DevHarnessView: View {
    @Environment(FogServices.self) private var services
    @Environment(ExplorationStore.self) private var explorationStore
    @State private var permissions = LocationPermissions()
    @State private var camera = CameraController()
    @State private var showDebug = false
    @State private var showCamera = false
    @State private var tileMath = TileMath()
    @State private var recenterToken = 0
    @State private var isFollowingUser = true

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            VStack(spacing: 8) {
                questPanel
                expeditionPanel
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    recenterToken &+= 1
                } label: {
                    Image(systemName: isFollowingUser ? "location.fill" : "location")
                        .padding(10)
                }
                .background(.thinMaterial, in: Circle())

                Button { showDebug = true } label: { Image(systemName: "ladybug").padding(10) }
                    .background(.thinMaterial, in: Circle())
            }
            .padding()
        }
        .overlay(alignment: .leading) {
            if services.debug.isSimulatorEnabled {
                JoystickView(simulator: services.location.simulator)
                    .padding(.leading, 24)
            }
        }
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

    private var questMarker: QuestMarkerData? {
        guard let quest = services.quests.today else { return nil }
        return QuestMarkerData(
            id: quest.id.uuidString,
            coordinate: quest.target.clCoordinate,
            title: quest.title,
            subtitle: quest.hint,
            systemImageName: "star.fill"
        )
    }

    private var activeRouteSegments: [[CLLocationCoordinate2D]] {
        guard let segments = services.expeditions.active?.segments else { return [] }
        return segments.map { $0.map(\.clCoordinate) }
    }

    private var map: some View {
        FogMapView(
            clearedCells: explorationStore.clearedCells,
            latestChange: explorationStore.latestChange,
            tileMath: tileMath,
            userCoordinate: (services.location.displayCoordinate
                             ?? services.location.currentCoordinate)?.clCoordinate,
            questMarker: questMarker,
            routeSegments: activeRouteSegments,
            recenterToken: recenterToken,
            onMapTap: { _ in },
            onFollowingChanged: { isFollowingUser = $0 }
        )
        .ignoresSafeArea()
    }

    // MARK: Quest

    private var questPanel: some View {
        let capture = services.questCapture
        return VStack(alignment: .leading, spacing: 4) {
            if let quest = services.quests.today {
                Text("\(quest.title) • \(quest.foundTodayCount) found today").font(.headline)
                if let d = capture.distanceToTarget {
                    Text("\(Int(d)) m away").font(.caption)
                }
            } else {
                Text(services.quests.isLoading ? "Loading quest…" : "No quest").font(.headline)
            }
            HStack {
                Text(stateText(capture.state)).font(.caption).lineLimit(2)
                Spacer()
                switch capture.state {
                case .ready:
                    Button("Take photo") { takePhoto() }.buttonStyle(.borderedProminent)
                case .rejected, .error:
                    Button("Retry") { capture.retry() }
                default:
                    EmptyView()
                }
            }
            Text("Cleared cells: \(explorationStore.clearedCells.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateText(_ s: QuestCaptureModel.State) -> String {
        switch s {
        case .noQuest: "No quest loaded"
        case .locked: "Locked: get within 40 m"
        case .ready: "In range: camera unlocked"
        case .verifying: "Verifying…"
        case .success(let sticker): "Collected \(sticker.category) sticker!"
        case .rejected(let reason, let left): "Not verified: \(reason) (\(left) left)"
        case .outOfAttempts: "Out of attempts today"
        case .error(let message): message
        }
    }

    private func takePhoto() {
        #if targetEnvironment(simulator)
        // No camera in the Simulator: submit a generated test image.
        Task { await services.questCapture.capture(Self.testImage()) }
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
            .padding(.bottom, 40)
        }
        .task { try? await camera.start() }
    }

    static func testImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.45, green: 0.3, blue: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 96, y: 200, width: 320, height: 60))
        ctx.fill(CGRect(x: 120, y: 120, width: 30, height: 80))
        ctx.fill(CGRect(x: 362, y: 120, width: 30, height: 80))
        return ctx.makeImage()!
    }

    // MARK: Expedition

    private var expeditionPanel: some View {
        let exp = services.expeditions
        return HStack {
            if let active = exp.active {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let secs = Int(context.date.timeIntervalSince(active.startedAt))
                    Text("\(Int(active.distanceMeters)) m • \(active.newTiles) tiles • \(secs / 60):\(String(format: "%02d", secs % 60))")
                        .font(.caption.monospacedDigit())
                }
                Spacer()
                Button("End") { exp.end() }.buttonStyle(.bordered).tint(.red)
            } else {
                Text("Sync: \(services.sync.pendingCount) pending").font(.caption)
                Spacer()
                Button("Start expedition") { exp.start() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Plain recap so the share export can be tested. Jonathan's designed card replaces this.
private struct RecapSheet: View {
    let summary: ExpeditionSummary

    var body: some View {
        VStack(spacing: 16) {
            card
            if let png = ShareImage.render(card) {
                ShareLink(item: png, preview: SharePreview("My expedition", image: png.preview)) {
                    Label("Share card", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .presentationDetents([.large])
    }

    private var card: some View {
        VStack(spacing: 12) {
            Text("Expedition complete").font(.title2.bold())
            Text("\(Int(summary.distanceMeters)) m walked")
            Text("\(summary.newTiles) new tiles")
            Text("\(Int(summary.duration / 60)) min")
            if let sticker = summary.sticker { Text("Quest: \(sticker.category) ⭐️") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
