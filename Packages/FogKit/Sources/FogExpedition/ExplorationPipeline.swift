import Foundation
import FogCore
import FogLocation

/// Glue between location and the fog: every accepted movement step clears tiles
/// around its interpolated path points (PRD F-2, F-4), counts them toward the active
/// expedition, and reports them for sync. Runs whenever location is running,
/// with or without an expedition, so the fog always clears while the app is open.
@MainActor
public final class ExplorationPipeline {
    public let explorer: ExplorationClearing
    public let expeditions: ExpeditionManager

    /// Newly cleared tiles (for `SyncQueue`).
    public var onTilesCleared: (([TileID]) -> Void)?
    /// Every accepted fix (for `location_pings` via `SyncQueue`), tagged with the active expedition.
    public var onPing: ((LocationPing) -> Void)?

    private var subscription: LocationSubscription?

    public init(location: LocationService, explorer: ExplorationClearing, expeditions: ExpeditionManager) {
        self.explorer = explorer
        self.expeditions = expeditions
        subscription = location.subscribe { [weak self] step in self?.handle(step) }
    }

    public func handle(_ step: LocationStep) {
        let newly = explorer.clearTiles(around: step.pathPoints)
        expeditions.record(step, newTiles: newly.count)
        if !newly.isEmpty { onTilesCleared?(newly) }
        onPing?(LocationPing(expeditionID: expeditions.active?.id, fix: step.fix))
    }

    /// Quest Reveal (PRD Q-9): clear everything within `radius` of the quest target.
    @discardableResult
    public func questReveal(at target: Coordinate, radius: Double = 150) -> [TileID] {
        let newly = explorer.clearArea(center: target, radiusMeters: radius)
        expeditions.addTiles(newly.count)
        if !newly.isEmpty { onTilesCleared?(newly) }
        return newly
    }
}
