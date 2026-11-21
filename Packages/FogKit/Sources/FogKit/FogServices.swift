@_exported import FogCore
@_exported import FogLocation
@_exported import FogNetworking
@_exported import FogExpedition
@_exported import FogQuest
@_exported import FogDebug
import Foundation
import Observation

/// Builds and wires every FogKit service. The app creates one at launch and puts it in the
/// SwiftUI environment:
///
/// ```swift
/// @main struct FogOfWarApp: App {
///     @State private var services = FogServices(explorer: explorationStore, auth: authService,
///                                               backend: BackendConfig(projectURL: ..., anonKey: ...))
///     var body: some Scene {
///         WindowGroup { RootTabView().environment(services).task { services.start() } }
///     }
/// }
/// ```
///
/// Pass `auth: nil` / `backend: nil` (or turn on "Mock backend" in the debug menu) to run
/// fully offline against `MockFogAPI`. `storageDirectory` defaults to Application Support/FogOfWar.
@MainActor
@Observable
public final class FogServices {
    public let debug: DebugSettings
    public let location: LocationService
    public let expeditions: ExpeditionManager
    public let history: ExpeditionHistory
    public let pipeline: ExplorationPipeline
    public let sync: SyncQueue
    public let quests: QuestService
    public let questCapture: QuestCaptureModel
    public let profile: ProfileModel
    public let api: FogAPI
    public let usingMockBackend: Bool

    @ObservationIgnored private let remoteVerifier: QuestVerifying
    @ObservationIgnored private let onDeviceVerifier = OnDeviceQuestVerifier()

    public init(explorer: ExplorationClearing,
                auth: AuthTokenProviding?,
                backend: BackendConfig?,
                debug: DebugSettings? = nil,
                storageDirectory: URL? = nil) {
        let debug = debug ?? DebugSettings()
        self.debug = debug

        let storage: StickerUploading?
        if let auth, let backend, !debug.useMockBackend {
            api = LiveFogAPI(config: backend, auth: auth)
            storage = SupabaseStickerStorage(config: backend, auth: auth)
            usingMockBackend = false
        } else {
            api = MockFogAPI()
            storage = nil
            usingMockBackend = true
        }

        location = LocationService()
        expeditions = ExpeditionManager(location: location)
        history = ExpeditionHistory(store: JSONFileStore(filename: "expeditions.json", directory: storageDirectory))
        sync = SyncQueue(api: api, store: JSONFileStore(filename: "pending-sync.json", directory: storageDirectory))
        pipeline = ExplorationPipeline(location: location, explorer: explorer, expeditions: expeditions)
        quests = QuestService(api: api)
        remoteVerifier = RemoteQuestVerifier(api: api)
        questCapture = QuestCaptureModel(verifier: remoteVerifier, remoteStorage: storage,
                                         localStorage: LocalStickerStorage(directory: storageDirectory?.appendingPathComponent("stickers")),
                                         location: location)
        profile = ProfileModel(api: api, history: history)

        wire()
        applyDebugSettings()
        observeDebugSettings()
    }

    /// Call once at launch (after location permission is granted, or it will prompt).
    public func start() {
        location.start()
        sync.startAutoSync()
        Task { await refreshQuest() }
    }

    /// Fetch today's quest for the current position and hand it to the capture flow.
    public func refreshQuest() async {
        let here = location.currentCoordinate ?? .westernCampus
        await quests.refresh(at: here)
        questCapture.setQuest(quests.today)
    }

    /// Demo "Reset fog" (PRD D-6).
    public func resetFog() {
        pipeline.explorer.resetAll()
        location.resetMovementTracking()
    }

    // MARK: Wiring

    private func wire() {
        let sync = self.sync, history = self.history, expeditions = self.expeditions
        let pipeline = self.pipeline, quests = self.quests, profile = self.profile

        pipeline.onTilesCleared = { sync.enqueue(tiles: $0) }
        pipeline.onPing = { sync.enqueue(ping: $0) }

        expeditions.onEnd = { summary in
            history.add(summary)
            sync.enqueue(expedition: summary)
            Task { await sync.flush() }
        }

        questCapture.onSuccess = { sticker, quest in
            expeditions.attach(sticker)
            quests.recordOwnFind()
            profile.addLocalSticker(sticker)
        }
    }

    private func applyDebugSettings() {
        location.setSimulating(debug.isSimulatorEnabled)
        questCapture.verifier = debug.useOnDeviceVerifier ? onDeviceVerifier : remoteVerifier
    }

    private func observeDebugSettings() {
        withObservationTracking {
            _ = debug.isSimulatorEnabled
            _ = debug.useOnDeviceVerifier
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyDebugSettings()
                self?.observeDebugSettings()
            }
        }
    }
}
