import CoreLocation
import Foundation
import MapKit
import SwiftyH3

/// Geometry prepared once in map-point space so renderers do not need to know
/// anything about the H3 package or repeat geographic projection work.
struct CellGeometry {
    let id: H3CellID
    let centerCoordinate: CLLocationCoordinate2D
    let centerMapPoint: MKMapPoint
    let boundary: [MKMapPoint]
    let mapRect: MKMapRect
}

enum TileMathError: Error, Equatable {
    case invalidCoordinate
    case invalidCell(H3CellID)
    case invalidRadius(CLLocationDistance)
    case invalidResolution(Int)
    case emptyBoundary(H3CellID)
    case radiusTooLarge(CLLocationDistance)
}

/// Geographic indexing and map projection for the exploration grid.
///
/// `SwiftyH3` is intentionally imported only by this file. Callers exchange
/// `H3CellID`, Core Location coordinates, and MapKit geometry instead.
public struct TileMath {
    static let explorationResolution = 11

    private static let h3Resolution: H3Cell.Resolution = .res11
    private static let maximumGridDiskDistance: Int32 = 128
    private static let approximateMinimumCellAreaSquareMeters = 1_500.0
    private static let approximateCellDiameterMeters = 50.0

    public init() {}

    public func cell(containing coordinate: CLLocationCoordinate2D) throws -> H3CellID {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw TileMathError.invalidCoordinate
        }

        let cell = try H3LatLng(coordinate).cell(at: Self.h3Resolution)
        return H3CellID(rawValue: cell.id)
    }

    public func boundary(for id: H3CellID) throws -> [MKMapPoint] {
        let cell = try h3Cell(for: id)
        return try cell.boundary.map { MKMapPoint($0.coordinates) }
    }

    public func center(for id: H3CellID) throws -> CLLocationCoordinate2D {
        let cell = try h3Cell(for: id)
        return try cell.center.coordinates
    }

    func geometry(for id: H3CellID) throws -> CellGeometry {
        try geometry(for: h3Cell(for: id))
    }

    public func parent(for id: H3CellID, resolution: Int) throws -> H3CellID {
        guard let rawResolution = Int32(exactly: resolution),
              let parentResolution = H3Cell.Resolution(rawValue: rawResolution)
        else {
            throw TileMathError.invalidResolution(resolution)
        }

        let parent = try h3Cell(for: id).parent(at: parentResolution)
        return H3CellID(rawValue: parent.id)
    }

    /// Returns every resolution-11 cell whose hexagon intersects the requested
    /// radius. `gridDisk` supplies a conservative candidate set, after which a
    /// local tangent-plane circle-versus-polygon test removes cells that do not
    /// actually touch the circle.
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

    /// Produces render-ready resolution-11 cells intersecting a visible map
    /// rectangle. At broad zoom levels this deliberately returns an empty array;
    /// callers should keep the base fog fill but omit tiny hex outlines.
    func visibleCells(in mapRect: MKMapRect, maxCount: Int) throws -> [CellGeometry] {
        guard maxCount > 0,
              let visibleRect = clippedToWorld(mapRect),
              estimatedCellCount(in: visibleRect) <= Double(maxCount)
        else {
            return []
        }

        let polygon = H3Polygon(rectangleCoordinates(for: visibleRect).map(H3LatLng.init))
        let cells = try polygon.cellsExperimental(
            at: Self.h3Resolution,
            containmentType: .overlapping
        )

        guard cells.count <= maxCount else {
            return []
        }

        var result: [CellGeometry] = []
        result.reserveCapacity(cells.count)

        for cell in cells {
            let cellGeometry = try geometry(for: cell)
            if mapRectsIntersect(cellGeometry.mapRect, visibleRect) {
                result.append(cellGeometry)
                if result.count > maxCount {
                    return []
                }
            }
        }

        return result.sorted { $0.id.rawValue < $1.id.rawValue }
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

    private func clippedToWorld(_ mapRect: MKMapRect) -> MKMapRect? {
        guard mapRect.origin.x.isFinite,
              mapRect.origin.y.isFinite,
              mapRect.size.width.isFinite,
              mapRect.size.height.isFinite,
              mapRect.size.width > 0,
              mapRect.size.height > 0
        else {
            return nil
        }

        let world = MKMapRect.world
        let minimumX = max(mapRect.minX, world.minX)
        let maximumX = min(mapRect.maxX, world.maxX)
        let minimumY = max(mapRect.minY, world.minY)
        let maximumY = min(mapRect.maxY, world.maxY)

        guard maximumX > minimumX, maximumY > minimumY else { return nil }

        return MKMapRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private func rectangleCoordinates(for mapRect: MKMapRect) -> [CLLocationCoordinate2D] {
        // Counter-clockwise in longitude/latitude space, as expected by H3.
        [
            MKMapPoint(x: mapRect.minX, y: mapRect.minY).coordinate,
            MKMapPoint(x: mapRect.minX, y: mapRect.maxY).coordinate,
            MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate,
            MKMapPoint(x: mapRect.maxX, y: mapRect.minY).coordinate,
        ]
    }

    private func estimatedCellCount(in mapRect: MKMapRect) -> Double {
        let center = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate
        let metersPerMapPoint = MKMetersPerMapPointAtLatitude(center.latitude)
        let widthMeters = mapRect.size.width * metersPerMapPoint
        let heightMeters = mapRect.size.height * metersPerMapPoint
        let areaEstimate = (widthMeters * heightMeters)
            / Self.approximateMinimumCellAreaSquareMeters
        let boundaryEstimate = (2 * (widthMeters + heightMeters))
            / Self.approximateCellDiameterMeters
        return ceil(areaEstimate + boundaryEstimate + 8)
    }

    private func mapRectsIntersect(_ first: MKMapRect, _ second: MKMapRect) -> Bool {
        first.minX <= second.maxX
            && first.maxX >= second.minX
            && first.minY <= second.maxY
            && first.maxY >= second.minY
    }
}

private struct LocalPoint {
    let x: Double
    let y: Double

    var lengthSquared: Double {
        (x * x) + (y * y)
    }
}
