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

    private let userID: String?
    private let onRestoreFog: (() -> Void)?

    /// - Parameters:
    ///   - userID: shown under Account so it can be copied for `npm run db:seed-demo -- --user <id>`.
    ///   - onRestoreFog: re-downloads this user's cleared tiles from the server (e.g. after seeding).
    public init(settings: DebugSettings, location: LocationService, onResetFog: @escaping () -> Void,
                userID: String? = nil, onRestoreFog: (() -> Void)? = nil) {
        self.settings = settings
        self.location = location
        self.onResetFog = onResetFog
        self.userID = userID
        self.onRestoreFog = onRestoreFog
    }

    private var simulator: SimulatedLocationProvider { location.simulator }

    public var body: some View {
        Form {
            Section {
                Toggle("Demo mode", isOn: Binding(
                    get: { settings.demoMode },
                    set: { on in
                        settings.demoMode = on
                        if on { simulator.boost = SimulatedLocationProvider.debugBoost }
                    }))
            } footer: {
                Text("Turns on simulated location and boost. Walk within range of a quest, open the camera, and its viewfinder shows a sample photo. Capture \"checks\" it for 3 seconds without calling Gemini, then the quest succeeds. Debug builds only.")
            }
            Section("Simulator Mode") {
                Toggle("Use simulated location", isOn: $settings.isSimulatorEnabled)
                if settings.isSimulatorEnabled {
                    Toggle("Boost (\(Int(SimulatedLocationProvider.debugBoost))x speed)", isOn: Binding(
                        get: { simulator.boost > 1 },
                        set: { simulator.boost = $0 ? SimulatedLocationProvider.debugBoost : 1 }))
                    if simulator.mode == .autoWalk {
                        Button("Stop Auto-Walk") { simulator.stopAutoWalk() }
                    } else {
                        Button("Auto-Walk demo route") { startDemoRoute() }
                    }
                    Button("Teleport to Western campus") { location.simulatorTeleport(to: .westernCampus) }
                    if let routeError { Text(routeError).foregroundStyle(.red) }
                }
            }
            Section {
                Toggle("On-device verifier (no network)", isOn: $settings.useOnDeviceVerifier)
                Toggle("Mock backend (applies on relaunch)", isOn: $settings.useMockBackend)
                Toggle("Bypass camera & Gemini", isOn: $settings.bypassQuestCamera)
            } header: {
                Text("Verification")
            } footer: {
                Text("Quest camera works anywhere; the shutter submits a test sticker, skips Gemini and completes the quest. Debug builds only.")
            }
            Section {
                Toggle("\(DebugSettings.fakeParticipantCount) explorers on every quest",
                       isOn: $settings.fakeParticipants)
                Button("Reset fog", role: .destructive) { confirmReset = true }
            } header: {
                Text("Demo")
            } footer: {
                Text("Overrides the real participant count everywhere it's shown.")
            }
            Section {
                Toggle("Override city explored", isOn: overrideBinding(\.cityExploredPercentOverride, default: 31))
                if let percent = settings.cityExploredPercentOverride {
                    HStack {
                        TextField("Percent", value: optionalBinding(\.cityExploredPercentOverride, default: percent),
                                  format: .number.precision(.fractionLength(0...2)))
                            .decimalKeyboard()
                        Text("%").foregroundStyle(.secondary)
                    }
                    Slider(value: optionalBinding(\.cityExploredPercentOverride, default: percent), in: 0...100, step: 1)
                }

                Toggle("Override city name", isOn: Binding(
                    get: { settings.cityNameOverride != nil },
                    set: { settings.cityNameOverride = $0 ? (settings.cityNameOverride ?? "London") : nil }))
                if settings.cityNameOverride != nil {
                    TextField("City", text: Binding(
                        get: { settings.cityNameOverride ?? "" },
                        set: { settings.cityNameOverride = $0 }))
                }

                Toggle("Override distance traveled", isOn: overrideBinding(\.distanceKmOverride, default: 129))
                if let km = settings.distanceKmOverride {
                    HStack {
                        TextField("Distance", value: optionalBinding(\.distanceKmOverride, default: km),
                                  format: .number.precision(.fractionLength(0...1)))
                            .decimalKeyboard()
                        Text("km").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Profile stats")
            } footer: {
                Text("Shown on the profile's green (city explored) and blue (distance) cards instead of the real numbers.")
            }
            Section("Account") {
                LabeledContent("Your user ID") {
                    Text(userID ?? "Not signed in yet")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let onRestoreFog {
                    Button("Restore fog from server", action: onRestoreFog)
                }
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

    /// On/off switch for an optional override; turning it on starts at `value`.
    private func overrideBinding(_ keyPath: ReferenceWritableKeyPath<DebugSettings, Double?>,
                                 default value: Double) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] != nil },
                set: { settings[keyPath: keyPath] = $0 ? (settings[keyPath: keyPath] ?? value) : nil })
    }

    /// Edits an override that is currently on, clamped to zero or more.
    private func optionalBinding(_ keyPath: ReferenceWritableKeyPath<DebugSettings, Double?>,
                                 default value: Double) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] ?? value },
                set: { settings[keyPath: keyPath] = max($0, 0) })
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

private extension View {
    /// Number pad on iOS; no-op elsewhere (FogKit also builds for macOS).
    @ViewBuilder func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
