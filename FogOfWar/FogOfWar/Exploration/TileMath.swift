import CoreLocation
import Foundation
import MapKit
import SwiftyH3

/// Geometry prepared once in map-point space so renderers do not need to know
/// anything about the H3 package or repeat geographic projection work.
nonisolated struct CellGeometry: Sendable {
    let id: H3CellID
    let centerCoordinate: CLLocationCoordinate2D
    let centerMapPoint: MKMapPoint
    let boundary: [MKMapPoint]
    let mapRect: MKMapRect
}

nonisolated enum TileMathError: Error, Equatable, Sendable {
    case invalidCoordinate
    case invalidCell(H3CellID)
    case invalidRadius(CLLocationDistance)
    case emptyBoundary(H3CellID)
    case radiusTooLarge(CLLocationDistance)
}

/// Geographic indexing and map projection for the exploration grid.
///
/// `SwiftyH3` is intentionally imported only by this file. Callers exchange
/// `H3CellID`, Core Location coordinates, and MapKit geometry instead.
///
/// Marked `nonisolated` so it can be constructed from default arguments and used
/// from MapKit overlay draw threads under the app's default MainActor isolation.
nonisolated public struct TileMath: Sendable {
    private static let h3Resolution: H3Cell.Resolution = .res11
    private static let maximumGridDiskDistance: Int32 = 128
    private static let approximateCellDiameterMeters = 50.0

    public init() {}

    public func cell(containing coordinate: CLLocationCoordinate2D) throws -> H3CellID {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw TileMathError.invalidCoordinate
        }

        let cell = try H3LatLng(coordinate).cell(at: Self.h3Resolution)
        return H3CellID(rawValue: cell.id)
    }

    /// Average area of a resolution-11 H3 hexagon (H3 reference tables).
    public static let averageCellAreaSquareMeters = 2_149.643

    /// Center of a cell, or `nil` for an invalid id. Cheaper than `geometry(for:)`.
    public func centerCoordinate(of id: H3CellID) -> CLLocationCoordinate2D? {
        guard let cell = try? h3Cell(for: id) else { return nil }
        return try? cell.center.coordinates
    }

    func geometry(for id: H3CellID) throws -> CellGeometry {
        try geometry(for: h3Cell(for: id))
    }

    /// Returns every resolution-11 cell whose hexagon intersects the requested
    /// radius. `gridDisk` supplies a conservative candidate set, after which a
    /// local tangent-plane circle-versus-polygon test removes cells that do not
    /// actually touch the circle.
    ///
    /// Because whole hexagons are cleared (not only centres inside the circle),
    /// the farthest cleared point can sit roughly one cell radius beyond
    /// `radiusMeters` — about **55 m** for the app's 30 m vision radius. See
    /// `ExplorationStore` for the product-facing note; this method's geometry
    /// is intentionally unchanged.
    public func cells(
        intersecting coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) throws -> Set<H3CellID> {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw TileMathError.invalidCoordinate
        }
        guard radiusMeters.isFinite, radiusMeters >= 0 else {
            throw TileMathError.invalidRadius(radiusMeters)
        }

        let originID = try cell(containing: coordinate)
        let originCell = try h3Cell(for: originID)
        let originGeometry = try geometry(for: originCell)
        let diskDistance = try conservativeDiskDistance(
            around: originCell,
            originGeometry: originGeometry,
            radiusMeters: radiusMeters
        )

        guard diskDistance <= Self.maximumGridDiskDistance else {
            throw TileMathError.radiusTooLarge(radiusMeters)
        }

        let circleCenter = MKMapPoint(coordinate)
        let candidates = try originCell.gridDisk(distance: diskDistance)

        return try Set(candidates.compactMap { candidate in
            let candidateGeometry = try geometry(for: candidate)
            if candidate.id == originCell.id {
                return candidateGeometry.id
            }

            guard polygon(
                candidateGeometry.boundary,
                intersectsCircleAt: circleCenter,
                latitude: coordinate.latitude,
                radiusMeters: radiusMeters
            ) else {
                return nil
            }

            return candidateGeometry.id
        })
    }

    private func h3Cell(for id: H3CellID) throws -> H3Cell {
        let cell = H3Cell(id.rawValue)
        guard cell.isValid else {
            throw TileMathError.invalidCell(id)
        }
        return cell
    }

    private func geometry(for cell: H3Cell) throws -> CellGeometry {
        let id = H3CellID(rawValue: cell.id)
        let centerCoordinate = try cell.center.coordinates
        let centerMapPoint = MKMapPoint(centerCoordinate)
        let boundary = try cell.boundary.map { MKMapPoint($0.coordinates) }

        guard let mapRect = boundingMapRect(for: boundary) else {
            throw TileMathError.emptyBoundary(id)
        }

        return CellGeometry(
            id: id,
            centerCoordinate: centerCoordinate,
            centerMapPoint: centerMapPoint,
            boundary: boundary,
            mapRect: mapRect
        )
    }

    private func conservativeDiskDistance(
        around origin: H3Cell,
        originGeometry: CellGeometry,
        radiusMeters: CLLocationDistance
    ) throws -> Int32 {
        let centerLocation = CLLocation(
            latitude: originGeometry.centerCoordinate.latitude,
            longitude: originGeometry.centerCoordinate.longitude
        )

        let cellRadius = try origin.boundary.reduce(0.0) { currentMaximum, vertex in
            let vertexLocation = CLLocation(
                latitude: vertex.latitudeDegs,
                longitude: vertex.longitudeDegs
            )
            return max(currentMaximum, centerLocation.distance(from: vertexLocation))
        }

        let neighborDistances = try origin.gridDisk(distance: 1).compactMap { neighbor -> Double? in
            guard neighbor.id != origin.id else { return nil }
            let neighborCoordinate = try neighbor.center.coordinates
            let neighborLocation = CLLocation(
                latitude: neighborCoordinate.latitude,
                longitude: neighborCoordinate.longitude
            )
            let distance = centerLocation.distance(from: neighborLocation)
            return distance > 1 ? distance : nil
        }

        // A ring's closest point advances slightly less than one neighbour-center
        // spacing in some H3 directions. The 0.65 factor plus two cell radii and
        // one extra ring intentionally overestimates before exact intersection.
        let neighborSpacing = neighborDistances.min()
            ?? max(cellRadius * 1.5, Self.approximateCellDiameterMeters)
        let conservativeRadialStep = max(neighborSpacing * 0.65, 1)
        let requiredDistance = (radiusMeters + (2 * cellRadius)) / conservativeRadialStep
        let ringCount = ceil(requiredDistance) + 1

        guard ringCount.isFinite, ringCount <= Double(Int32.max) else {
            throw TileMathError.radiusTooLarge(radiusMeters)
        }

        return Int32(max(1, ringCount))
    }

    private func polygon(
        _ boundary: [MKMapPoint],
        intersectsCircleAt circleCenter: MKMapPoint,
        latitude: CLLocationDegrees,
        radiusMeters: CLLocationDistance
    ) -> Bool {
        guard boundary.count >= 3 else { return false }

        let metersPerMapPoint = MKMetersPerMapPointAtLatitude(latitude)
        let worldWidth = MKMapRect.world.size.width
        let localPoints = boundary.map { point in
            var deltaX = point.x - circleCenter.x
            if deltaX > worldWidth / 2 { deltaX -= worldWidth }
            if deltaX < -worldWidth / 2 { deltaX += worldWidth }

            return LocalPoint(
                x: deltaX * metersPerMapPoint,
                y: (point.y - circleCenter.y) * metersPerMapPoint
            )
        }

        if pointIsInsidePolygon(localPoints) {
            return true
        }

        let radiusSquared = radiusMeters * radiusMeters
        if localPoints.contains(where: { $0.lengthSquared <= radiusSquared }) {
            return true
        }

        for index in localPoints.indices {
            let start = localPoints[index]
            let end = localPoints[(index + 1) % localPoints.count]
            if squaredDistanceFromOrigin(toSegmentFrom: start, to: end) <= radiusSquared {
                return true
            }
        }

        return false
    }

    /// Ray casting for the local origin. A boundary hit is handled separately by
    /// the point-to-edge distance test, so strict crossings are sufficient here.
    private func pointIsInsidePolygon(_ points: [LocalPoint]) -> Bool {
        var isInside = false

        for index in points.indices {
            let first = points[index]
            let second = points[(index + 1) % points.count]
            let crossesHorizontalRay = (first.y > 0) != (second.y > 0)
            guard crossesHorizontalRay else { continue }

            let crossingX = first.x + ((second.x - first.x) * (-first.y) / (second.y - first.y))
            if crossingX > 0 {
                isInside.toggle()
            }
        }

        return isInside
    }

    private func squaredDistanceFromOrigin(
        toSegmentFrom start: LocalPoint,
        to end: LocalPoint
    ) -> Double {
        let segmentX = end.x - start.x
        let segmentY = end.y - start.y
        let segmentLengthSquared = (segmentX * segmentX) + (segmentY * segmentY)

        guard segmentLengthSquared > 0 else {
            return start.lengthSquared
        }

        let projection = -((start.x * segmentX) + (start.y * segmentY)) / segmentLengthSquared
        let clampedProjection = min(max(projection, 0), 1)
        let closestX = start.x + (clampedProjection * segmentX)
        let closestY = start.y + (clampedProjection * segmentY)
        return (closestX * closestX) + (closestY * closestY)
    }

    private func boundingMapRect(for points: [MKMapPoint]) -> MKMapRect? {
        guard let first = points.first else { return nil }

        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y

        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }

        return MKMapRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

}

nonisolated private struct LocalPoint: Sendable {
    let x: Double
    let y: Double

    var lengthSquared: Double {
        (x * x) + (y * y)
    }
}
