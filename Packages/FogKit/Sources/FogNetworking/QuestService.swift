import Foundation
import Observation
import FogCore

/// Today's quests for the user's region (docs/api.md §3, PRD Q-1, Q-11, Q-13). A region can have
/// several; the player picks one (`select`). `today` is the selected quest, which the capture flow,
/// the active-quest card and the map's highlighted marker use. `options` lists them all.
@MainActor
@Observable
public final class QuestService {
    /// Every quest in the region today, in server order. Empty when there's none (`status` says why).
    public private(set) var options: [QuestOption] = []
    /// The quest the player picked (defaults to the first one they haven't completed).
    public private(set) var selectedID: UUID?
    public private(set) var status: QuestStatus?
    /// When `status == .quietHours`: when the next quest appears.
    public private(set) var availableAt: Date?
    /// Next local midnight; refetch after it.
    public private(set) var resetsAt: Date?
    public private(set) var regionH3: String?
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
            options = r.appQuests
            if !options.contains(where: { $0.id == selectedID }) {
                selectedID = (options.first { !$0.completedByMe } ?? options.first)?.id
            }
            status = r.status
            availableAt = r.availableAt
            resetsAt = r.resetsAt
            regionH3 = r.regionH3
            fetchedAt = Date()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// The selected quest; nil when there's no quest (`status` says why).
    public var today: Quest? { selected?.quest }
    public var completedByMe: Bool { selected?.completedByMe ?? false }
    public var attemptsLeft: Int { selected?.attemptsLeft ?? 5 }
    public var selected: QuestOption? { options.first { $0.id == selectedID } }

    /// Picks which of today's quests is active. Ignores ids that aren't in `options`.
    public func select(_ id: UUID) {
        guard options.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// True before the first fetch or once `resets_at` has passed.
    public func isStale(now: Date = Date()) -> Bool {
        guard fetchedAt != nil, let resetsAt else { return true }
        return now >= resetsAt
    }

    /// Update after the user's own verified find, without waiting for a refetch.
    public func recordOwnFind() {
        guard let i = options.firstIndex(where: { $0.id == selectedID }) else { return }
        options[i].quest.foundTodayCount += 1
        options[i].completedByMe = true
    }
}
