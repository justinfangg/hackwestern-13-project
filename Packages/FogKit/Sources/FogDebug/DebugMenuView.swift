import SwiftUI
import FogCore
import FogLocation

/// Debug/demo controls (PRD D-1 to D-6). Present as a sheet once `settings.isMenuUnlocked`.
public struct DebugMenuView: View {
    @Bindable private var settings: DebugSettings
    private let location: LocationService
    private let onResetFog: () -> Void
    @State private var routeError: String?
    @State private var confirmReset = false

    public init(settings: DebugSettings, location: LocationService, onResetFog: @escaping () -> Void) {
        self.settings = settings
        self.location = location
        self.onResetFog = onResetFog
    }

    private var simulator: SimulatedLocationProvider { location.simulator }

    public var body: some View {
        Form {
            Section("Simulator Mode") {
                Toggle("Use simulated location", isOn: $settings.isSimulatorEnabled)
                if settings.isSimulatorEnabled {
                    Toggle("Boost (5x speed)", isOn: Binding(
                        get: { simulator.boost > 1 },
                        set: { simulator.boost = $0 ? 5 : 1 }))
                    if simulator.mode == .autoWalk {
                        Button("Stop Auto-Walk") { simulator.stopAutoWalk() }
                    } else {
                        Button("Auto-Walk demo route") { startDemoRoute() }
                    }
                    Button("Teleport to Western campus") { location.simulatorTeleport(to: .westernCampus) }
                    if let routeError { Text(routeError).foregroundStyle(.red) }
                }
            }
            Section("Verification") {
                Toggle("On-device verifier (no network)", isOn: $settings.useOnDeviceVerifier)
                Toggle("Mock backend (applies on relaunch)", isOn: $settings.useMockBackend)
            }
            Section("Demo reset") {
                Button("Reset fog", role: .destructive) { confirmReset = true }
            }
            Section("Status") {
                LabeledContent("Source", value: location.isSimulating ? "Simulator" : "GPS")
                if let c = location.currentCoordinate {
                    LabeledContent("Position", value: String(format: "%.5f, %.5f", c.latitude, c.longitude))
                }
                if let r = location.lastRejection {
                    LabeledContent("Last rejected fix", value: String(describing: r))
                }
            }
        }
        .confirmationDialog("Clear all explored tiles?", isPresented: $confirmReset) {
            Button("Reset fog", role: .destructive, action: onResetFog)
        }
    }

    private func startDemoRoute() {
        do {
            location.simulatorAutoWalk(try GPXParser.bundledDemoRoute())
            routeError = nil
        } catch {
            routeError = "Couldn't load demo-route.gpx"
        }
    }
}
