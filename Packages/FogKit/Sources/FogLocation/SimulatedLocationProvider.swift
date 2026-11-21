import Foundation
import Observation
import FogCore

/// Fake GPS for the stage demo and for testing indoors (PRD D-2, D-3).
/// Two ways to move: an on-screen joystick, or Auto-Walk along a GPX route.
/// Emits fixes through the same pipeline as real GPS.
@MainActor
@Observable
public final class SimulatedLocationProvider: LocationProvider {
    public enum Mode: Equatable { case idle, joystick, autoWalk }

    @ObservationIgnored public var onFix: ((LocationFix) -> Void)?

    public private(set) var position: Coordinate
    public private(set) var mode: Mode = .idle
    public private(set) var isRunning = false

    /// Walking speed in m/s (PRD D-2: ~1.4).
    public var walkingSpeed: Double = 1.4
    /// Speed multiplier for the joystick boost and Auto-Walk (PRD D-2: 5x).
    public var boost: Double = 1
    /// How often fixes are emitted.
    public var tickInterval: TimeInterval = 0.5

    /// Joystick vector, x = east, y = north, each in -1...1.
    @ObservationIgnored private var stick: (x: Double, y: Double) = (0, 0)
    @ObservationIgnored private var route: [Coordinate] = []
    @ObservationIgnored private var routeIndex = 0
    @ObservationIgnored private var loopRoute = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var clock: () -> Date

    public init(start: Coordinate = .westernCampus, clock: @escaping () -> Date = Date.init) {
        self.position = start
        self.clock = clock
    }

    // MARK: LocationProvider

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        emit(speed: 0)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tickInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                self?.tick(dt: interval)
            }
        }
    }

    public func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    public func setBackgroundUpdates(_ enabled: Bool) {}

    // MARK: Controls

    /// Joystick input; x = east, y = north, magnitude clamped to 1. Pass (0, 0) on release.
    public func setJoystick(x: Double, y: Double) {
        let m = (x * x + y * y).squareRoot()
        let scale = m > 1 ? 1 / m : 1
        stick = (x * scale, y * scale)
        if m > 0.05 { mode = .joystick } else if mode == .joystick { mode = .idle }
    }

    /// Start walking a route (e.g. from `GPXParser`). Jumps to its first point.
    public func startAutoWalk(_ coordinates: [Coordinate], loop: Bool = false) {
        guard let first = coordinates.first else { return }
        route = coordinates
        routeIndex = 1
        loopRoute = loop
        teleport(to: first)
        mode = .autoWalk
    }

    public func stopAutoWalk() {
        route = []
        if mode == .autoWalk { mode = .idle }
    }

    /// Jump without walking (no fog is cleared along the way: the filter treats a big jump
    /// as too fast, and the next fix far away starts a new segment).
    public func teleport(to c: Coordinate) {
        position = c
    }

    // MARK: Movement

    /// Advance the simulation by `dt` seconds. Called by the timer; public for tests.
    public func tick(dt: TimeInterval) {
        let speed = walkingSpeed * boost
        switch mode {
        case .idle:
            emit(speed: 0)
        case .joystick:
            let metres = speed * dt
            position = Geo.offset(position, north: stick.y * metres, east: stick.x * metres)
            emit(speed: speed * (stick.x * stick.x + stick.y * stick.y).squareRoot())
        case .autoWalk:
            var remaining = speed * dt
            while remaining > 0, routeIndex < route.count {
                let next = route[routeIndex]
                let d = Geo.distance(position, next)
                if d <= remaining {
                    position = next
                    remaining -= d
                    routeIndex += 1
                } else {
                    position = Geo.lerp(position, next, remaining / d)
                    remaining = 0
                }
            }
            if routeIndex >= route.count {
                if loopRoute, route.count > 1 {
                    routeIndex = 0 // walk back to the start and go again
                } else {
                    stopAutoWalk()
                }
            }
            emit(speed: speed)
        }
    }

    private func emit(speed: Double) {
        onFix?(LocationFix(coordinate: position, timestamp: clock(), horizontalAccuracy: 5,
                           speed: speed, source: .simulated))
    }
}
