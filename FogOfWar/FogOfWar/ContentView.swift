//
//  ContentView.swift
//  FogOfWar
//

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
    ContentView()
        .environment(FogServices(explorer: GridExplorer(), auth: nil, backend: nil))
}
