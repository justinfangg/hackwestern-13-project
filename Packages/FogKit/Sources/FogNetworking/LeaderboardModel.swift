import Foundation
import Observation
import FogCore

/// Territory leaderboards (docs/api.md §7): pick an area and a metric, see the ranking.
/// The leaderboard page reads `areas`, `selectedArea`, `metric`, `board`; calls `load(near:)`,
/// `select(area:)` and `select(metric:)`.
@MainActor
@Observable
public final class LeaderboardModel {
    public private(set) var areas: [TerritoryArea] = []
    public private(set) var selectedAreaID: String?
    public private(set) var metric: LeaderboardMetric = .percent
    public private(set) var board: LeaderboardResponse?
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    @ObservationIgnored private let api: FogAPI
    @ObservationIgnored private var loadToken = UUID()

    public init(api: FogAPI) { self.api = api }

    public var selectedArea: TerritoryArea? { areas.first { $0.id == selectedAreaID } }

    /// Loads the areas (nearest first) and the ranking for the selected (or nearest) area.
    public func load(near location: Coordinate?, metric: LeaderboardMetric? = nil) async {
        if let metric { self.metric = metric }
        isLoading = true
        defer { isLoading = false }
        do {
            areas = try await api.leaderboardAreas(near: location).areas
            if selectedAreaID == nil || !areas.contains(where: { $0.id == selectedAreaID }) {
                selectedAreaID = areas.first?.id
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
            return
        }
        await refreshBoard()
    }

    public func select(area id: String) async {
        guard id != selectedAreaID else { return }
        selectedAreaID = id
        await refreshBoard()
    }

    public func select(metric: LeaderboardMetric) async {
        guard metric != self.metric else { return }
        self.metric = metric
        await refreshBoard()
    }

    /// Re-fetches the ranking; ignores responses that arrive after a newer selection.
    public func refreshBoard() async {
        guard let area = selectedAreaID else { board = nil; return }
        let token = UUID()
        loadToken = token
        let metric = self.metric
        isLoading = true
        defer { if loadToken == token { isLoading = false } }
        do {
            let result = try await api.leaderboard(area: area, metric: metric)
            guard loadToken == token else { return }
            board = result
            lastError = nil
        } catch {
            guard loadToken == token else { return }
            lastError = String(describing: error)
        }
    }
}
