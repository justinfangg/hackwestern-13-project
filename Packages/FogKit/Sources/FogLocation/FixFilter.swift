import Foundation
import FogCore

/// Rejects GPS fixes that would clear fog incorrectly (PRD F-8) and decides
/// when a new route segment starts.
public struct FixFilter: Sendable {
    public struct Config: Sendable {
        /// Reject fixes less accurate than this (metres).
        public var maxAccuracy: Double = 50
        /// Reject fixes implying faster movement than this (m/s). ~54 km/h: covers cycling, not cars.
        public var maxSpeed: Double = 15
        /// Ignore fixes that moved less than this from the last accepted one (jitter while standing still).
        public var minDistance: Double = 3
        /// After this many consecutive speed rejections, accept the next fix as the start of a new
        /// segment (the user really did move, e.g. took a bus). Prevents getting stuck forever.
        public var resetAfterSpeedRejections: Int = 3
        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        /// Use the fix. `newSegment` = don't connect it to the previous fix (no interpolation, no route line).
        case accept(newSegment: Bool)
        case reject(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case inaccurate, tooFast, tooClose, outOfOrder
    }

    public var config: Config
    public private(set) var lastAccepted: LocationFix?
    private var speedRejections = 0

    public init(config: Config = Config()) { self.config = config }

    public mutating func reset() {
        lastAccepted = nil
        speedRejections = 0
    }

    public mutating func evaluate(_ fix: LocationFix) -> Decision {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= config.maxAccuracy else {
            return .reject(.inaccurate)
        }
        guard let prev = lastAccepted else {
            lastAccepted = fix
            return .accept(newSegment: true)
        }
        let dt = fix.timestamp.timeIntervalSince(prev.timestamp)
        guard dt > 0 else { return .reject(.outOfOrder) }

        let d = Geo.distance(prev.coordinate, fix.coordinate)
        if d / dt > config.maxSpeed {
            speedRejections += 1
            if speedRejections >= config.resetAfterSpeedRejections {
                speedRejections = 0
                lastAccepted = fix
                return .accept(newSegment: true)
            }
            return .reject(.tooFast)
        }
        speedRejections = 0
        guard d >= config.minDistance else { return .reject(.tooClose) }
        lastAccepted = fix
        return .accept(newSegment: false)
    }
}
