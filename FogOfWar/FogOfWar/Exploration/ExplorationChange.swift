import CoreLocation
import Foundation

/// Describes which system initiated an exploration update.
nonisolated public enum ExplorationSource: String, Codable, Hashable, Sendable {
    case location
    /// Retained for Codable compatibility. The old debug tap-to-reveal UI that
    /// bypassed FogKit was removed so exploration stays on the location pipeline.
    case debugTap = "debug_tap"
    case external
}

/// A single incremental reveal published after its cells are persisted.
nonisolated public struct ExplorationChange: Identifiable, Sendable {
    public let id: UUID
    public let newlyClearedCells: Set<H3CellID>
    public let source: ExplorationSource
    public let origin: CLLocationCoordinate2D?
    public let radiusMeters: CLLocationDistance?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        newlyClearedCells: Set<H3CellID>,
        source: ExplorationSource,
        origin: CLLocationCoordinate2D? = nil,
        radiusMeters: CLLocationDistance? = nil,
        timestamp: Date = .now
    ) {
        self.id = id
        self.newlyClearedCells = newlyClearedCells
        self.source = source
        self.origin = origin
        self.radiusMeters = radiusMeters
        self.timestamp = timestamp
    }

    /// Compatibility shorthand for renderers and synchronization queues.
    public var cells: Set<H3CellID> { newlyClearedCells }

    public var count: Int { newlyClearedCells.count }
}
