import Foundation
import Observation
import FogCore

/// Local list of finished expeditions, newest first (PRD P-4; also feeds Ayman's path tracing, P-2).
@MainActor
@Observable
public final class ExpeditionHistory {
    public private(set) var expeditions: [ExpeditionSummary]
    @ObservationIgnored private let store: JSONFileStore<[ExpeditionSummary]>?

    public init(store: JSONFileStore<[ExpeditionSummary]>? = JSONFileStore(filename: "expeditions.json")) {
        self.store = store
        self.expeditions = store?.load() ?? []
    }

    public func add(_ summary: ExpeditionSummary) {
        expeditions.insert(summary, at: 0)
        store?.save(expeditions)
    }

    /// All route segments ever walked, for the path-tracing map.
    public var allSegments: [[Coordinate]] { expeditions.flatMap(\.segments) }

    public var totalDistanceMeters: Double { expeditions.reduce(0) { $0 + $1.distanceMeters } }

    public func removeAll() {
        expeditions.removeAll()
        store?.save(expeditions)
    }
}
