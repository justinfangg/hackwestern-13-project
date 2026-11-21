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

    /// FogKit services talking to the real Supabase backend (SupabaseConfig).
    /// Sign-in is FogKit's minimal anonymous auth until Jonathan's AuthService lands.
    /// Debug menu → "Mock backend" switches to the offline fake (applies on relaunch).
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
            auth: SupabaseAnonymousAuth(config: SupabaseConfig.backend),
            backend: SupabaseConfig.backend
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
