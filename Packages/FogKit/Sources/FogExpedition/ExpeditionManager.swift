import Foundation
import Observation
import FogCore
import FogLocation

/// Start/End expedition tracking (PRD E-1, E-4).
/// The Map tab's Start/End button and live stats read this; the recap card reads `lastSummary`.
@MainActor
@Observable
public final class ExpeditionManager {
    /// The expedition in progress, with live stats for the HUD.
    public struct Active: Equatable, Sendable {
        public var id: UUID
        public var startedAt: Date
        public var distanceMeters: Double = 0
        public var newTiles: Int = 0
        public var segments: [[Coordinate]] = []
        public var sticker: Sticker?
    }

    public private(set) var active: Active?
    /// Summary of the most recently ended expedition (show the recap card when this changes).
    public private(set) var lastSummary: ExpeditionSummary?
    public var isActive: Bool { active != nil }

    /// Called with the finished summary (FogKit wires this to history + sync).
    @ObservationIgnored public var onEnd: ((ExpeditionSummary) -> Void)?

    @ObservationIgnored private let location: LocationService?
    @ObservationIgnored private let clock: () -> Date

    public init(location: LocationService?, clock: @escaping () -> Date = Date.init) {
        self.location = location
        self.clock = clock
    }

    public func start() {
        guard active == nil else { return }
        var a = Active(id: UUID(), startedAt: clock())
        if let here = location?.currentCoordinate { a.segments = [[here]] }
        active = a
        location?.start()
        location?.setBackgroundUpdates(true)
    }

    @discardableResult
    public func end() -> ExpeditionSummary? {
        guard let a = active else { return nil }
        active = nil
        location?.setBackgroundUpdates(false)
        let summary = ExpeditionSummary(id: a.id, startedAt: a.startedAt, endedAt: clock(),
                                        distanceMeters: a.distanceMeters, newTiles: a.newTiles,
                                        segments: a.segments.filter { !$0.isEmpty }, sticker: a.sticker)
        lastSummary = summary
        onEnd?(summary)
        return summary
    }

    /// Called by `ExplorationPipeline` for every accepted step.
    public func record(_ step: LocationStep, newTiles: Int) {
        guard var a = active else { return }
        let c = step.fix.coordinate
        if step.newSegment || a.segments.isEmpty {
            a.segments.append([c])
        } else {
            if let last = a.segments[a.segments.count - 1].last {
                a.distanceMeters += Geo.distance(last, c)
            }
            a.segments[a.segments.count - 1].append(c)
        }
        a.newTiles += newTiles
        active = a
    }

    public func addTiles(_ count: Int) {
        active?.newTiles += count
    }

    /// Attach the Daily Quest sticker to the running expedition (shown on the recap card).
    public func attach(_ sticker: Sticker) {
        active?.sticker = sticker
    }

    public func dismissSummary() { lastSummary = nil }
}
