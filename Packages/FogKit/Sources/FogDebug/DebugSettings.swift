import Foundation
import Observation
import SwiftUI

/// Demo/debug switches (PRD D-1, §14). Persisted in UserDefaults so they survive relaunches on stage.
@MainActor
@Observable
public final class DebugSettings {
    /// Hidden until unlocked with a triple-tap (PRD D-1).
    public var isMenuUnlocked: Bool { didSet { defaults.set(isMenuUnlocked, forKey: Keys.unlocked) } }
    public var isSimulatorEnabled: Bool { didSet { defaults.set(isSimulatorEnabled, forKey: Keys.simulator) } }
    /// Use Apple's on-device classifier instead of the Edge Function (flaky Wi-Fi fallback).
    public var useOnDeviceVerifier: Bool {
        didSet {
            defaults.set(useOnDeviceVerifier, forKey: Keys.onDevice)
            if useOnDeviceVerifier { demoMode = false } // demo mode is for testing Gemini
        }
    }
    /// Use the in-memory mock backend instead of Supabase.
    public var useMockBackend: Bool { didSet { defaults.set(useMockBackend, forKey: Keys.mock) } }
    /// Debug only: the quest camera always works (any location), the shutter submits a bundled test
    /// sticker instead of a real photo, and the quest completes without calling the verifier.
    public var bypassQuestCamera: Bool {
        didSet {
            defaults.set(bypassQuestCamera, forKey: Keys.bypassCamera)
            if bypassQuestCamera { demoMode = false } // the two cameras are alternatives
        }
    }
    /// Demo mode (Simulator demos): simulated location on, and the quest camera's viewfinder shows a
    /// bundled sample photo that the shutter captures. You still walk into range; then the photo is
    /// "checked" for a few seconds without calling the verifier and the quest succeeds (see
    /// `QuestCaptureModel.demoAutoSuccess`). The app turns boost on.
    public var demoMode: Bool {
        didSet {
            defaults.set(demoMode, forKey: Keys.demoMode)
            guard demoMode else { return }
            isSimulatorEnabled = true
            bypassQuestCamera = false
            useOnDeviceVerifier = false
        }
    }
    /// Show every quest as having `fakeParticipantCount` explorers (demo: avatars, "+N" pill).
    public var fakeParticipants: Bool { didSet { defaults.set(fakeParticipants, forKey: Keys.fakeParticipants) } }

    /// Demo values for the profile's stat cards; `nil` shows the real numbers.
    public var cityExploredPercentOverride: Double? {
        didSet { defaults.set(cityExploredPercentOverride, forKey: Keys.cityPercent) }
    }
    public var cityNameOverride: String? {
        didSet { defaults.set(cityNameOverride, forKey: Keys.cityName) }
    }
    public var distanceKmOverride: Double? {
        didSet { defaults.set(distanceKmOverride, forKey: Keys.distanceKm) }
    }

    public static let fakeParticipantCount = 6

    /// `bypassQuestCamera`, but never in a release build, even if the flag was left on in UserDefaults.
    public var isQuestCameraBypassActive: Bool {
        #if DEBUG
        bypassQuestCamera
        #else
        false
        #endif
    }

    /// `demoMode`, but never in a release build.
    public var isDemoCameraActive: Bool {
        #if DEBUG
        demoMode
        #else
        false
        #endif
    }

    /// The participant count to display for a quest whose real count is `real`.
    public func participantCount(real: Int) -> Int {
        fakeParticipants ? Self.fakeParticipantCount : real
    }

    /// The city-explored percentage (0…100) to display.
    public func cityExploredPercent(real: Double?) -> Double? {
        cityExploredPercentOverride ?? real
    }

    /// The city name to display on the profile.
    public func cityName(real: String?) -> String? {
        cityNameOverride ?? real
    }

    /// Total quest distance to display, in meters.
    public func distanceMeters(real: Double) -> Double {
        distanceKmOverride.map { $0 * 1000 } ?? real
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let unlocked = "debug.unlocked", simulator = "debug.simulator"
        static let onDevice = "debug.onDeviceVerifier", mock = "debug.mockBackend"
        static let fakeParticipants = "debug.fakeParticipants"
        static let bypassCamera = "debug.bypassQuestCamera", demoMode = "debug.demoMode"
        static let cityPercent = "debug.profile.cityPercent", cityName = "debug.profile.cityName"
        static let distanceKm = "debug.profile.distanceKm"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isMenuUnlocked = defaults.bool(forKey: Keys.unlocked)
        isSimulatorEnabled = defaults.bool(forKey: Keys.simulator)
        useOnDeviceVerifier = defaults.bool(forKey: Keys.onDevice)
        useMockBackend = defaults.bool(forKey: Keys.mock)
        fakeParticipants = defaults.bool(forKey: Keys.fakeParticipants)
        bypassQuestCamera = defaults.bool(forKey: Keys.bypassCamera)
        demoMode = defaults.bool(forKey: Keys.demoMode)
        // Settings saved before demo mode switched these off (didSet doesn't run in init).
        if demoMode {
            useOnDeviceVerifier = false
            bypassQuestCamera = false
            defaults.set(false, forKey: Keys.onDevice)
            defaults.set(false, forKey: Keys.bypassCamera)
        }
        cityExploredPercentOverride = defaults.object(forKey: Keys.cityPercent) as? Double
        cityNameOverride = defaults.string(forKey: Keys.cityName)
        distanceKmOverride = defaults.object(forKey: Keys.distanceKm) as? Double
    }
}

extension View {
    /// Triple-tap this view (e.g. the app logo) to unlock the debug menu (PRD D-1).
    public func debugUnlockGesture(_ settings: DebugSettings) -> some View {
        onTapGesture(count: 3) { settings.isMenuUnlocked.toggle() }
    }
}
