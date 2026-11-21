import Foundation
import Observation
import FogCore
import FogNetworking
import FogExpedition

/// Data for the Profile tab (PRD P-1 to P-5). Jonathan's Profile views read this;
/// Ayman's path-tracing map reads `routeSegments`.
/// Works offline: local expeditions and newly collected stickers show before the server responds.
@MainActor
@Observable
public final class ProfileModel {
    public private(set) var remote: ProfileResponse?
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    /// Stickers collected on this device that the server may not have returned yet.
    public private(set) var localStickers: [Sticker] = []

    @ObservationIgnored private let api: FogAPI
    @ObservationIgnored private let history: ExpeditionHistory

    public init(api: FogAPI, history: ExpeditionHistory) {
        self.api = api
        self.history = history
    }

    public var username: String { remote?.username ?? "Explorer" }

    /// Newest first, de-duplicated by quest.
    public var stickers: [Sticker] {
        var seen = Set<UUID>()
        return (localStickers + (remote?.stickers ?? []))
            .sorted { $0.collectedAt > $1.collectedAt }
            .filter { seen.insert($0.questID).inserted }
    }

    public var missedQuestDates: [String] { remote?.missedQuestDates ?? [] }

    /// Lifetime stats (P-3); falls back to local data before the first fetch.
    public var stats: ProfileStats {
        if let s = remote?.stats { return s }
        return ProfileStats(tilesCleared: history.expeditions.reduce(0) { $0 + $1.newTiles },
                            distanceM: history.totalDistanceMeters,
                            questsCompleted: stickers.count, currentStreak: 0)
    }

    public var weeklyActivity: [WeeklyActivity] { remote?.weeklyActivity ?? [] }
    public var expeditions: [ExpeditionSummary] { history.expeditions }
    public var routeSegments: [[Coordinate]] { history.allSegments }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            remote = try await api.profile()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    public func addLocalSticker(_ sticker: Sticker) {
        localStickers.insert(sticker, at: 0)
    }
}
