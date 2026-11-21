import Foundation

/// Square-grid stand-in for Ayman's H3 `ExplorationStore`.
/// Used by tests, previews, and as the PRD §14 fallback if the H3 package won't build.
/// Cells are ~20 m × 20 m; IDs pack (latIndex, lngIndex) into a UInt64.
@MainActor
public final class GridExplorer: ExplorationClearing {
    public let cellSize: Double
    public let visionRadius: Double
    public private(set) var cleared: Set<TileID> = []

    public init(cellSize: Double = 20, visionRadius: Double = 30) {
        self.cellSize = cellSize
        self.visionRadius = visionRadius
    }

    public func clearTiles(around points: [Coordinate]) -> [TileID] {
        var newly: [TileID] = []
        for p in points { newly += clear(center: p, radius: visionRadius) }
        return newly
    }

    public func clearArea(center: Coordinate, radiusMeters: Double) -> [TileID] {
        clear(center: center, radius: radiusMeters)
    }

    public func resetAll() { cleared.removeAll() }

    // MARK: Grid math

    private var dLat: Double { cellSize / Geo.earthRadius * 180 / .pi }

    private func dLng(at lat: Double) -> Double {
        // Fixed per latitude row so cells line up; uses the row's own latitude.
        cellSize / (Geo.earthRadius * cos(lat * .pi / 180)) * 180 / .pi
    }

    public func tile(for c: Coordinate) -> TileID {
        let row = Int64((c.latitude / dLat).rounded(.down))
        let rowLat = (Double(row) + 0.5) * dLat
        let col = Int64((c.longitude / dLng(at: rowLat)).rounded(.down))
        return Self.pack(row, col)
    }

    public func center(of tile: TileID) -> Coordinate {
        let (row, col) = Self.unpack(tile)
        let lat = (Double(row) + 0.5) * dLat
        return Coordinate(latitude: lat, longitude: (Double(col) + 0.5) * dLng(at: lat))
    }

    private func clear(center: Coordinate, radius: Double) -> [TileID] {
        let steps = Int((radius / cellSize).rounded(.up)) + 1
        var newly: [TileID] = []
        for dy in -steps...steps {
            for dx in -steps...steps {
                let probe = Geo.offset(center, north: Double(dy) * cellSize, east: Double(dx) * cellSize)
                let t = tile(for: probe)
                guard Geo.distance(self.center(of: t), center) <= radius else { continue }
                if cleared.insert(t).inserted { newly.append(t) }
            }
        }
        return newly
    }

    private static func pack(_ row: Int64, _ col: Int64) -> TileID {
        let r = UInt64(bitPattern: row &+ Int64(Int32.max)) & 0xFFFF_FFFF
        let c = UInt64(bitPattern: col &+ Int64(Int32.max)) & 0xFFFF_FFFF
        return TileID(r << 32 | c)
    }

    private static func unpack(_ t: TileID) -> (Int64, Int64) {
        (Int64(t.rawValue >> 32) - Int64(Int32.max), Int64(t.rawValue & 0xFFFF_FFFF) - Int64(Int32.max))
    }
}
