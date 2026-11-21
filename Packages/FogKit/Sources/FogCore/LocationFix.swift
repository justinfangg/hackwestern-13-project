import Foundation
import CoreLocation

/// One position reading, from real GPS or the simulator.
/// Everything downstream (filtering, clearing, expeditions, geofence) consumes this type,
/// so real and simulated movement go through exactly the same code (PRD D-4).
public struct LocationFix: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case gps, simulated }

    public var coordinate: Coordinate
    public var timestamp: Date
    /// Horizontal accuracy radius in metres. Negative means invalid.
    public var horizontalAccuracy: Double
    /// Reported speed in m/s, if known.
    public var speed: Double?
    public var source: Source

    public init(coordinate: Coordinate, timestamp: Date, horizontalAccuracy: Double = 5,
                speed: Double? = nil, source: Source = .gps) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.source = source
    }

    public init(_ location: CLLocation, source: Source = .gps) {
        self.init(coordinate: Coordinate(location.coordinate),
                  timestamp: location.timestamp,
                  horizontalAccuracy: location.horizontalAccuracy,
                  speed: location.speed >= 0 ? location.speed : nil,
                  source: source)
    }
}
