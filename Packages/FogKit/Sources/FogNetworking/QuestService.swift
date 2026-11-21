import Foundation
import Observation
import FogCore

/// Today's Daily Quest for the user's region (docs/api.md §3, PRD Q-1, Q-11, Q-13).
/// Jonathan's quest card reads `today` / `status`; Ayman's map reads `today?.target` for the marker.
@MainActor
@Observable
public final class QuestService {
    /// nil when there's no quest (`status` says why).
    public private(set) var today: Quest?
    public private(set) var status: QuestStatus?
    /// When `status == .quietHours`: when the next quest appears.
    public private(set) var availableAt: Date?
    /// Next local midnight; refetch after it.
    public private(set) var resetsAt: Date?
    public private(set) var regionH3: String?
    public private(set) var completedByMe = false
    public private(set) var attemptsLeft = 5
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public private(set) var fetchedAt: Date?

    @ObservationIgnored private let api: FogAPI

    public init(api: FogAPI) { self.api = api }

    /// Fetches today's quest for the region containing `location`.
    public func refresh(at location: Coordinate) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await api.questToday(at: location)
            today = r.appQuest
            status = r.status
            availableAt = r.availableAt
            resetsAt = r.resetsAt
            regionH3 = r.regionH3
            completedByMe = r.completedByMe
            attemptsLeft = r.attemptsLeft
            fetchedAt = Date()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// True before the first fetch or once `resets_at` has passed.
    public func isStale(now: Date = Date()) -> Bool {
        guard fetchedAt != nil, let resetsAt else { return true }
        return now >= resetsAt
    }

    /// Update after the user's own verified find, without waiting for a refetch.
    public func recordOwnFind() {
        today?.foundTodayCount += 1
        completedByMe = true
    }
}
