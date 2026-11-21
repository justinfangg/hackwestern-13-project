import Foundation
import CoreLocation

/// A WGS84 coordinate. Codable/Sendable stand-in for `CLLocationCoordinate2D`.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    // JSON uses { "lat": …, "lng": … } (docs/api.md §1).
    private enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lng"
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Default spot for the simulator and previews: University College, Western University.
    public static let westernCampus = Coordinate(latitude: 43.0096, longitude: -81.2737)
}

public enum Geo {
    public static let earthRadius = 6_371_008.8 // metres

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Moves `origin` by the given metres north and east (flat-earth approximation, fine below ~10 km).
    public static func offset(_ origin: Coordinate, north: Double, east: Double) -> Coordinate {
        let dLat = north / earthRadius * 180 / .pi
        let dLng = east / (earthRadius * cos(origin.latitude * .pi / 180)) * 180 / .pi
        return Coordinate(latitude: origin.latitude + dLat, longitude: origin.longitude + dLng)
    }

    /// Linear interpolation between two nearby coordinates, `t` in 0...1.
    public static func lerp(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                   longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Total length in metres of a polyline.
    public static func length(of path: [Coordinate]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}

extension Coordinate {
    public func distance(to other: Coordinate) -> Double { Geo.distance(self, other) }
}
