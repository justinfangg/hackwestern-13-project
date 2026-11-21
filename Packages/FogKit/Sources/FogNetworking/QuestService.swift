import Foundation
import Observation
import FogCore

/// Today's Daily Quest for the user's region (PRD Q-1, Q-11).
/// Jonathan's quest card reads `today`; Ayman's map reads `today?.target` for the marker (Q-4).
@MainActor
@Observable
public final class QuestService {
    public private(set) var today: Quest?
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    /// When `today` was fetched; refresh again after local midnight (PRD Q-13).
    public private(set) var fetchedAt: Date?

    @ObservationIgnored private let api: FogAPI

    public init(api: FogAPI) { self.api = api }

    /// Fetches today's quest for the region containing `location`.
    public func refresh(at location: Coordinate) async {
        isLoading = true
        defer { isLoading = false }
        do {
            today = try await api.questToday(at: location).quest
            fetchedAt = Date()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// True if the cached quest is from a previous local day.
    public func isStale(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let fetchedAt else { return true }
        return !calendar.isDate(fetchedAt, inSameDayAs: now)
    }

    /// Optimistically bump the "N found today" count after the user's own verified find.
    public func recordOwnFind() {
        today?.foundTodayCount += 1
    }
}
