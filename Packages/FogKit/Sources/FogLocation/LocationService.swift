import Foundation
import Observation
import FogCore

/// One accepted movement step, delivered to every subscriber.
public struct LocationStep: Sendable, Equatable {
    /// The accepted fix.
    public var fix: LocationFix
    /// True if this fix starts a new route segment (first fix, or after a GPS gap/jump).
    public var newSegment: Bool
    /// Points to clear fog around: interpolated every ~10 m since the previous fix, ending at `fix`.
    public var pathPoints: [Coordinate]
}

/// The single entry point for location in the app.
///
/// Raw fixes from the active provider (real GPS or simulator) → `FixFilter` → `PathInterpolator`
/// → fanned out to every subscriber (fog clearing, expeditions, quest geofence).
/// Views can read `currentCoordinate` directly (it's `@Observable`).
@MainActor
@Observable
public final class LocationService {
    public private(set) var currentFix: LocationFix?
    public var currentCoordinate: Coordinate? { currentFix?.coordinate }
    public private(set) var isRunning = false
    public private(set) var isSimulating = false
    /// Last rejection reason, for the debug overlay.
    public private(set) var lastRejection: FixFilter.Reason?

    public let realProvider: LocationProvider
    public let simulator: SimulatedLocationProvider

    @ObservationIgnored private var filter: FixFilter
    @ObservationIgnored private var subscribers: [UUID: (LocationStep) -> Void] = [:]
    @ObservationIgnored private var backgroundEnabled = false

    public init(realProvider: LocationProvider? = nil,
                simulator: SimulatedLocationProvider? = nil,
                filterConfig: FixFilter.Config = .init()) {
        self.realProvider = realProvider ?? RealLocationProvider()
        self.simulator = simulator ?? SimulatedLocationProvider()
        self.filter = FixFilter(config: filterConfig)
        self.realProvider.onFix = { [weak self] in self?.handle($0) }
        self.simulator.onFix = { [weak self] in self?.handle($0) }
    }

    private var activeProvider: LocationProvider { isSimulating ? simulator : realProvider }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        activeProvider.start()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        activeProvider.stop()
    }

    /// Switch between real GPS and Simulator Mode (PRD D-1). Resets filtering so the
    /// jump between real and simulated positions doesn't count as movement.
    public func setSimulating(_ on: Bool) {
        guard on != isSimulating else { return }
        let wasRunning = isRunning
        if wasRunning { activeProvider.stop() }
        activeProvider.setBackgroundUpdates(false)
        isSimulating = on
        filter.reset()
        if on, let here = currentCoordinate { simulator.teleport(to: here) }
        activeProvider.setBackgroundUpdates(backgroundEnabled)
        if wasRunning { activeProvider.start() }
    }

    public func setBackgroundUpdates(_ enabled: Bool) {
        backgroundEnabled = enabled
        activeProvider.setBackgroundUpdates(enabled)
    }

    /// Forget the last position so the next fix starts a new segment (no line or fog drawn
    /// across a jump). Use after teleporting the simulator.
    public func resetMovementTracking() {
        filter.reset()
    }

    /// Simulator helpers that jump without clearing fog along the way.
    public func simulatorTeleport(to c: Coordinate) {
        simulator.teleport(to: c)
        filter.reset()
    }

    public func simulatorAutoWalk(_ route: [Coordinate], loop: Bool = false) {
        simulator.startAutoWalk(route, loop: loop)
        filter.reset()
    }

    /// Subscribe to accepted movement. Keep the returned token; the subscription ends when it's released.
    public func subscribe(_ handler: @escaping (LocationStep) -> Void) -> LocationSubscription {
        let id = UUID()
        subscribers[id] = handler
        return LocationSubscription { [weak self] in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
    }

    /// Feed a fix directly (used by tests and by providers).
    public func handle(_ fix: LocationFix) {
        let previous = filter.lastAccepted
        switch filter.evaluate(fix) {
        case .reject(let reason):
            lastRejection = reason
        case .accept(let newSegment):
            lastRejection = nil
            currentFix = fix
            var points = [fix.coordinate]
            if !newSegment, let previous {
                points = PathInterpolator.points(from: previous.coordinate, to: fix.coordinate)
            }
            let step = LocationStep(fix: fix, newSegment: newSegment, pathPoints: points)
            for handler in subscribers.values { handler(step) }
        }
    }
}

/// Ends a `LocationService` subscription when cancelled or deallocated.
public final class LocationSubscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel?(); onCancel = nil }
    deinit { onCancel?() }
}
