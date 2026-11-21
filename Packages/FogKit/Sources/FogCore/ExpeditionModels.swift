import Foundation

/// Everything the recap card (Jonathan) and sync need about a finished expedition (PRD E-2).
public struct ExpeditionSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var distanceMeters: Double
    public var newTiles: Int
    /// Route split into continuous segments (a GPS gap starts a new segment; don't draw a line across it).
    public var segments: [[Coordinate]]
    /// Sticker collected during this expedition, if the Daily Quest was completed.
    public var sticker: Sticker?

    public init(id: UUID, startedAt: Date, endedAt: Date, distanceMeters: Double, newTiles: Int,
                segments: [[Coordinate]], sticker: Sticker? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.newTiles = newTiles
        self.segments = segments
        self.sticker = sticker
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var route: [Coordinate] { segments.flatMap { $0 } }

    public static let sample: ExpeditionSummary = {
        let start = Coordinate.westernCampus
        let pts = (0...40).map { Geo.offset(start, north: Double($0) * 10, east: sin(Double($0) / 6) * 40) }
        let begin = Date(timeIntervalSince1970: 1_795_000_000)
        return ExpeditionSummary(id: UUID(), startedAt: begin, endedAt: begin.addingTimeInterval(1_740),
                                 distanceMeters: Geo.length(of: pts), newTiles: 87, segments: [pts])
    }()
}

/// A GPS fix as stored in the `location_pings` table.
public struct LocationPing: Hashable, Codable, Sendable {
    public var expeditionID: UUID?
    public var timestamp: Date
    public var coordinate: Coordinate
    public var accuracy: Double
    public var speed: Double?

    public init(expeditionID: UUID?, fix: LocationFix) {
        self.expeditionID = expeditionID
        self.timestamp = fix.timestamp
        self.coordinate = fix.coordinate
        self.accuracy = fix.horizontalAccuracy
        self.speed = fix.speed
    }
}
