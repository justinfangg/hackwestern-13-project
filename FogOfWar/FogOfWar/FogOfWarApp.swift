//
//  FogOfWarApp.swift
//  FogOfWar
//

import SwiftUI
import FogKit

@main
struct FogOfWarApp: App {
    // Temporary wiring until teammates' pieces land:
    // - explorer: GridExplorer → Ayman's ExplorationStore
    // - auth/backend: nil (mock backend) → Jonathan's AuthService + Supabase project settings
    @State private var services = FogServices(explorer: GridExplorer(), auth: nil, backend: nil)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
        }
    }
}
