//
//  ContentView.swift
//  FogOfWar
//

import SwiftData
import SwiftUI
import FogKit

/// Root view. For now it shows the developer test screen; Jonathan replaces this
/// with the real TabView (Map + Profile) when the designed screens are ready.
struct ContentView: View {
    var body: some View {
        DevHarnessView()
    }
}

#Preview {
    let container = try! ModelContainer(
        for: ExploredCellRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = ExplorationStore(modelContainer: container)
    ContentView()
        .environment(FogServices(explorer: store, auth: nil, backend: nil))
        .environment(store)
        .modelContainer(container)
}
