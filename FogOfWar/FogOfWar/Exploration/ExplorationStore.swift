import Combine
import CoreLocation
import Foundation
import FogKit
import Observation
import SwiftData

/// Offline-first source of truth for explored H3 cells.
///
/// The store is main-actor isolated so SwiftData writes, Observation updates,
/// and renderer notifications are delivered in a predictable order.
///
/// ## Vision radius vs effective clear footprint
/// `visionRadiusMeters` (30 m) is the geometric circle passed to
/// `TileMath.cells(intersecting:radiusMeters:)`. That API clears every H3
/// resolution-11 cell whose hexagon **intersects** the circle, not only cells
/// whose centres lie inside it. At res 11 (~25 m edge, ~50 m across) a cell that
/// merely brushes the circle can extend ~25 m beyond it, so the **effective
/// cleared footprint is roughly 55 m** from the fix. This PR documents that
/// behaviour; the intersection algorithm itself is unchanged.
@MainActor
@Observable
public final class ExplorationStore: ExplorationClearing {
    public static let visionRadiusMeters: CLLocationDistance = 30

    public private(set) var clearedCells: Set<H3CellID>
    public private(set) var latestChange: ExplorationChange?
    public private(set) var latestErrorDescription: String?

    /// Emits only successful, non-empty incremental clears.
    public let changes = PassthroughSubject<ExplorationChange, Never>()

    private let modelContext: ModelContext
    private let tileMath: TileMath

    public init(modelContext: ModelContext, tileMath: TileMath) {
        self.modelContext = modelContext
        self.tileMath = tileMath
        self.clearedCells = []
        self.latestChange = nil
        self.latestErrorDescription = nil

        restorePersistedCells()
    }

    public convenience init(modelContext: ModelContext) {
        self.init(modelContext: modelContext, tileMath: TileMath())
    }

    public convenience init(modelContainer: ModelContainer, tileMath: TileMath) {
        self.init(modelContext: modelContainer.mainContext, tileMath: tileMath)
    }

    public convenience init(modelContainer: ModelContainer) {
        self.init(modelContext: modelContainer.mainContext, tileMath: TileMath())
    }

    public var changePublisher: AnyPublisher<ExplorationChange, Never> {
        changes.eraseToAnyPublisher()
    }

    public func isCleared(_ cell: H3CellID) -> Bool {
        clearedCells.contains(cell)
    }

    /// Clears a set of cells originating outside a radius-based reveal.
    @discardableResult
    public func clear<Cells: Sequence>(cells: Cells) -> Set<H3CellID>
    where Cells.Element == H3CellID {
        clear(cells: cells, source: .external)
    }

    /// Clears cells and publishes only the subset that was not already known.
    @discardableResult
    public func clear<Cells: Sequence>(
        cells: Cells,
        source: ExplorationSource,
        origin: CLLocationCoordinate2D? = nil,
        radiusMeters: CLLocationDistance? = nil
    ) -> Set<H3CellID>
    where Cells.Element == H3CellID {
        let newlyCleared = Set(cells).subtracting(clearedCells)

        guard !newlyCleared.isEmpty else {
            latestErrorDescription = nil
            return []
        }

        let timestamp = Date.now
        let insertedRecords = newlyCleared.map {
            ExploredCellRecord(cellID: $0, firstClearedAt: timestamp)
        }

        insertedRecords.forEach(modelContext.insert)

        do {
            try modelContext.save()
        } catch {
            insertedRecords.forEach(modelContext.delete)
            latestErrorDescription = "Unable to save explored cells: \(error.localizedDescription)"
            return []
        }

        clearedCells.formUnion(newlyCleared)
        latestErrorDescription = nil

        let change = ExplorationChange(
            newlyClearedCells: newlyCleared,
            source: source,
            origin: origin,
            radiusMeters: radiusMeters,
            timestamp: timestamp
        )
        latestChange = change
        changes.send(change)

        return newlyCleared
    }

    /// Resolves and clears every H3 cell intersecting the supplied radius.
    @discardableResult
    public func reveal(
        at coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        source: ExplorationSource = .location
    ) -> Set<H3CellID> {
        do {
            let cells = try tileMath.cells(
                intersecting: coordinate,
                radiusMeters: radiusMeters
            )

            return clear(
                cells: cells,
                source: source,
                origin: coordinate,
                radiusMeters: radiusMeters
            )
        } catch {
            latestErrorDescription = "Unable to calculate reveal cells: \(error.localizedDescription)"
            return []
        }
    }

    /// Integration point for Justin's validated/interpolated location fixes.
    /// The store remains independent of Core Location ownership and clears only
    /// the standard vision radius defined by the exploration module.
    @discardableResult
    public func revealVision(
        at coordinate: CLLocationCoordinate2D
    ) -> Set<H3CellID> {
        reveal(
            at: coordinate,
            radiusMeters: Self.visionRadiusMeters,
            source: .location
        )
    }

    /// FogKit integration point. Justin's pipeline has already validated and
    /// interpolated these points, so this performs one atomic H3/persistence
    /// update and returns only newly discovered IDs for sync and expedition stats.
    @discardableResult
    public func clearTiles(around points: [Coordinate]) -> [TileID] {
        guard !points.isEmpty else { return [] }

        var cells = Set<H3CellID>()
        do {
            for point in points {
                cells.formUnion(try tileMath.cells(
                    intersecting: point.clCoordinate,
                    radiusMeters: Self.visionRadiusMeters
                ))
            }
        } catch {
            latestErrorDescription = "Unable to calculate reveal cells: \(error.localizedDescription)"
            return []
        }

        let newlyCleared = clear(
            cells: cells,
            source: .location,
            origin: points.last?.clCoordinate,
            radiusMeters: Self.visionRadiusMeters
        )
        return newlyCleared.map(\.tileID).sorted()
    }

    public func resetAll() {
        resetExploration()
    }

    // MARK: Restore from server (FogKit, docs/api.md D8). Added by Justin.

    public var clearedTileCount: Int { clearedCells.count }

    /// Tiles from `GET profile?include=tiles` after a reinstall. Published as an `.external` change
    /// with no origin, so the map redraws without the reveal animation.
    @discardableResult
    public func restore(tiles: [TileID]) -> Int {
        clear(cells: tiles.map(H3CellID.init), source: .external).count
    }

    public func resetExploration() {
        do {
            let records = try modelContext.fetch(FetchDescriptor<ExploredCellRecord>())
            records.forEach(modelContext.delete)
            try modelContext.save()

            clearedCells.removeAll(keepingCapacity: true)
            latestChange = nil
            latestErrorDescription = nil
        } catch {
            latestErrorDescription = "Unable to reset exploration: \(error.localizedDescription)"
        }
    }

    private func restorePersistedCells() {
        do {
            let records = try modelContext.fetch(FetchDescriptor<ExploredCellRecord>())
            clearedCells = Set(records.compactMap(\.cellID))
            latestErrorDescription = nil
        } catch {
            clearedCells = []
            latestErrorDescription = "Unable to restore exploration: \(error.localizedDescription)"
        }
    }
}
