//
//  ContentView.swift
//  FogOfWar
//

import SwiftData
import SwiftUI
import FogKit

/// Root view: the designed map + profile split (see `MainView`).
struct ContentView: View {
    var body: some View {
        MainView()
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
