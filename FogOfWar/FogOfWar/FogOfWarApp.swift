//
//  FogOfWarApp.swift
//  FogOfWar
//

import SwiftData
import SwiftUI
import FogKit

@main
struct FogOfWarApp: App {
    /// SwiftData container for H3 exploration persistence (Ayman).
    private let modelContainer: ModelContainer

    /// Offline-first H3 exploration store. Same instance is handed to FogKit.
    @State private var explorationStore: ExplorationStore

    /// Temporary wiring until Jonathan's AuthService + Supabase backend land:
    /// auth/backend stay nil so the app runs against `MockFogAPI`.
    @State private var services: FogServices

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: ExploredCellRecord.self)
        } catch {
            fatalError("Unable to create exploration ModelContainer: \(error)")
        }

        let store = ExplorationStore(modelContainer: container)
        self.modelContainer = container
        _explorationStore = State(initialValue: store)
        _services = State(initialValue: FogServices(
            explorer: store,
            auth: nil,
            backend: nil
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
                .environment(explorationStore)
                .modelContainer(modelContainer)
        }
    }
}
