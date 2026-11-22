import Foundation
import Observation
import FogCore

/// The leaderboard (docs/api.md §7): everyone at Western University's campus, ranked by % explored,
/// time or distance over today, this week or this month. The leaderboard page reads `board`,
/// `metric`, `period`; calls `load(near:)`, `select(metric:)` and `select(period:)`.
@MainActor
@Observable
public final class LeaderboardModel {
    public private(set) var metric: LeaderboardMetric = .percent
    public private(set) var period: LeaderboardPeriod = .week
    public private(set) var board: CityLeaderboardResponse?
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    @ObservationIgnored private let api: FogAPI
    @ObservationIgnored private var location: Coordinate?
    @ObservationIgnored private var loadToken = UUID()

    public init(api: FogAPI) { self.api = api }

    /// The city the board is for (nil before loading, or when you're not near a city).
    public var city: LeaderboardResponse.Area? { board?.area }

    /// Loads the board for the city around `location`.
    public func load(near location: Coordinate?, metric: LeaderboardMetric? = nil) async {
        if let metric { self.metric = metric }
        if let location { self.location = location }
        await refresh()
    }

    public func select(metric: LeaderboardMetric) async {
        guard metric != self.metric else { return }
        self.metric = metric
        await refresh()
    }

    public func select(period: LeaderboardPeriod) async {
        guard period != self.period else { return }
        self.period = period
        await refresh()
    }

    /// Re-fetches; ignores responses that arrive after a newer selection.
    public func refresh() async {
        let token = UUID()
        loadToken = token
        let (metric, period) = (self.metric, self.period)
        let here = location ?? .westernCampus
        isLoading = true
        defer { if loadToken == token { isLoading = false } }
        do {
            let result = try await api.cityLeaderboard(near: here, metric: metric, period: period)
            guard loadToken == token else { return }
            board = result
            lastError = nil
        } catch {
            guard loadToken == token else { return }
            lastError = String(describing: error)
        }
    }
}
