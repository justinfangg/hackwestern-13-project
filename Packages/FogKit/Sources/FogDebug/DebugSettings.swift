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
    public var useOnDeviceVerifier: Bool { didSet { defaults.set(useOnDeviceVerifier, forKey: Keys.onDevice) } }
    /// Use the in-memory mock backend instead of Supabase.
    public var useMockBackend: Bool { didSet { defaults.set(useMockBackend, forKey: Keys.mock) } }
    /// Show every quest as having `fakeParticipantCount` explorers (demo: avatars, "+N" pill).
    public var fakeParticipants: Bool { didSet { defaults.set(fakeParticipants, forKey: Keys.fakeParticipants) } }

    public static let fakeParticipantCount = 6

    /// The participant count to display for a quest whose real count is `real`.
    public func participantCount(real: Int) -> Int {
        fakeParticipants ? Self.fakeParticipantCount : real
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let unlocked = "debug.unlocked", simulator = "debug.simulator"
        static let onDevice = "debug.onDeviceVerifier", mock = "debug.mockBackend"
        static let fakeParticipants = "debug.fakeParticipants"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isMenuUnlocked = defaults.bool(forKey: Keys.unlocked)
        isSimulatorEnabled = defaults.bool(forKey: Keys.simulator)
        useOnDeviceVerifier = defaults.bool(forKey: Keys.onDevice)
        useMockBackend = defaults.bool(forKey: Keys.mock)
        fakeParticipants = defaults.bool(forKey: Keys.fakeParticipants)
    }
}

extension View {
    /// Triple-tap this view (e.g. the app logo) to unlock the debug menu (PRD D-1).
    public func debugUnlockGesture(_ settings: DebugSettings) -> some View {
        onTapGesture(count: 3) { settings.isMenuUnlocked.toggle() }
    }
}
