import CoreLocation
import MapKit
import Observation

/// Works out which city the player is in and how much of it they've uncovered
/// (the green "Location Summary" card on the profile, Figma 46:2404).
///
/// The city is found by reverse geocoding the player's position, and its
/// extent comes from a Maps search for that city (the search's bounding
/// region). Coverage is the area of cleared H3 cells inside that extent over
/// the extent's area, so it reads as "% of the city explored".
@MainActor
@Observable
final class CityCoverage {
    struct City: Equatable, Sendable {
        var name: String
        /// Approximate city extent; coverage treats it as the ellipse inscribed in it.
        var region: MKCoordinateRegion

        static func == (lhs: City, rhs: City) -> Bool {
            lhs.name == rhs.name
                && lhs.region.center.latitude == rhs.region.center.latitude
                && lhs.region.center.longitude == rhs.region.center.longitude
                && lhs.region.span.latitudeDelta == rhs.region.span.latitudeDelta
                && lhs.region.span.longitudeDelta == rhs.region.span.longitudeDelta
        }
    }

    private(set) var city: City?

    @ObservationIgnored private var lookedUpAt: CLLocation?
    @ObservationIgnored private var isLookingUp = false

    /// Re-run the lookup only after moving this far from the last one.
    private static let relookupDistance: CLLocationDistance = 4_000
    /// Used when Maps can't give a sensible city extent (radius in meters).
    private static let fallbackRadius: CLLocationDistance = 8_000

    /// Finds the city around `coordinate` if it hasn't been found nearby already.
    func locate(near coordinate: CLLocationCoordinate2D) async {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let lookedUpAt, city != nil, here.distance(from: lookedUpAt) < Self.relookupDistance { return }
        guard !isLookingUp else { return }
        isLookingUp = true
        defer { isLookingUp = false }

        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(here).first else { return }
        let name = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? "Your city"
        let region = await Self.extent(of: placemark, name: name) ?? Self.fallbackRegion(around: coordinate)
        lookedUpAt = here
        city = City(name: name, region: region)
    }

    /// Percentage (0…100) of the city covered by `cells`, or `nil` before the city is known.
    func percentExplored(by cells: Set<H3CellID>) async -> Double? {
        guard let city else { return nil }
        return await Task.detached(priority: .utility) {
            Self.percent(of: city.region, coveredBy: cells)
        }.value
    }

    // MARK: Geometry

    nonisolated private static func percent(of region: MKCoordinateRegion, coveredBy cells: Set<H3CellID>) -> Double {
        let tileMath = TileMath()
        let center = region.center
        let semiLat = region.span.latitudeDelta / 2
        let semiLon = region.span.longitudeDelta / 2
        guard semiLat > 0, semiLon > 0 else { return 0 }

        var inside = 0
        for cell in cells {
            guard let point = tileMath.centerCoordinate(of: cell) else { continue }
            let dy = (point.latitude - center.latitude) / semiLat
            let dx = (point.longitude - center.longitude) / semiLon
            if dx * dx + dy * dy <= 1 { inside += 1 }
        }

        // Ellipse inscribed in the region, measured on the ground.
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(center.latitude * .pi / 180)
        let area = Double.pi * (semiLat * metersPerDegreeLat) * (semiLon * metersPerDegreeLon)
        guard area > 0 else { return 0 }
        let covered = Double(inside) * TileMath.averageCellAreaSquareMeters
        return min(covered / area * 100, 100)
    }

    /// The city's extent from a Maps search, rejecting results that are clearly
    /// not a city (a single building, or a whole province).
    private static func extent(of placemark: CLPlacemark, name: String) async -> MKCoordinateRegion? {
        let query = [name, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .joined(separator: ", ")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address
        if let location = placemark.location {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let region = response.boundingRegion
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        guard (0.02...2).contains(span) else { return nil }
        return region
    }

    private static func fallbackRegion(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: fallbackRadius * 2, longitudinalMeters: fallbackRadius * 2)
    }
}
