import Foundation
import Observation
import FogCore
import FogNetworking
import FogExpedition

/// Data for the Profile tab (PRD P-1 to P-5, docs/api.md §5–6). Jonathan's Profile views read this;
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
    /// Keeps `localStickers` across launches: debug-bypass stickers never reach the server, and a real
    /// find shows before the server returns it.
    @ObservationIgnored private let localStickerStore: JSONFileStore<[Sticker]>?

    public init(api: FogAPI, history: ExpeditionHistory, localStickerStore: JSONFileStore<[Sticker]>? = nil) {
        self.api = api
        self.history = history
        self.localStickerStore = localStickerStore
        if let store = localStickerStore, let saved = store.load() {
            localStickers = saved.map { Self.relocated($0, stickersDirectory: Self.stickersDirectory(for: store)) }
        }
    }

    /// `LocalStickerStorage`'s folder (Application Support/FogOfWar/stickers) beside the store's file.
    private static func stickersDirectory(for store: JSONFileStore<[Sticker]>) -> URL {
        store.url.deletingLastPathComponent().appendingPathComponent("stickers", isDirectory: true)
    }

    /// The app's container path can change between installs, so a saved absolute image path is
    /// re-pointed at the same file name in the current sticker folder.
    private static func relocated(_ sticker: Sticker, stickersDirectory: URL) -> Sticker {
        guard let saved = sticker.localImageURL else { return sticker }
        var sticker = sticker
        let current = stickersDirectory.appendingPathComponent(saved.lastPathComponent)
        if FileManager.default.fileExists(atPath: current.path) {
            sticker.localImageURL = current
        } else if !FileManager.default.fileExists(atPath: saved.path) {
            sticker.localImageURL = nil
        }
        return sticker
    }

    /// nil until a username is set (onboarding calls `setUsername`).
    public var username: String? { remote?.username }

    /// Newest first, de-duplicated by quest.
    public var stickers: [Sticker] {
        var seen = Set<UUID>()
        return (localStickers + (remote?.stickers.map(\.sticker) ?? []))
            .sorted { $0.collectedAt > $1.collectedAt }
            .filter { seen.insert($0.questID).inserted }
    }

    /// Days with no completion, for greyed-out silhouettes (Q-13).
    public var missedDays: [MissedDay] { remote?.missedDays ?? [] }

    /// Lifetime stats (P-3); falls back to local data before the first fetch.
    public var stats: ProfileStats {
        if let s = remote?.stats { return s }
        return ProfileStats(tilesCleared: history.expeditions.reduce(0) { $0 + $1.newTiles },
                            distanceM: history.totalDistanceMeters,
                            questsCompleted: stickers.count, currentStreak: 0)
    }

    /// Last 8 weeks, oldest first (P-5).
    public var weeklyActivity: [WeeklyActivity] { remote?.weeklyActivity ?? [] }

    /// Local expeditions plus ones only the server knows about (e.g. after a reinstall), newest first.
    public var expeditions: [ExpeditionSummary] {
        let local = history.expeditions
        let localIDs = Set(local.map(\.id))
        let routes = Dictionary((remote?.routes ?? []).map { ($0.expeditionId, $0.points) }, uniquingKeysWith: { a, _ in a })
        let remoteOnly = (remote?.expeditions ?? []).filter { !localIDs.contains($0.id) }.map {
            ExpeditionSummary(id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt, distanceMeters: $0.distanceM,
                              newTiles: $0.newTiles, segments: routes[$0.id].map { [$0] } ?? [])
        }
        return (local + remoteOnly).sorted { $0.startedAt > $1.startedAt }
    }

    /// Every walked route segment, for the path-tracing map (P-2). Don't join segments.
    public var routeSegments: [[Coordinate]] { expeditions.flatMap(\.segments) }

    public func refresh(includeTiles: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            remote = try await api.profile(includeTiles: includeTiles)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Set or change the username (onboarding). Throws `APIError` with code `invalid_username` or
    /// `username_taken` (docs/api.md §6).
    @discardableResult
    public func setUsername(_ username: String) async throws -> ProfileIdentity {
        let identity = try await api.setUsername(username)
        remote?.username = identity.username
        return identity
    }

    public func addLocalSticker(_ sticker: Sticker) {
        localStickers.insert(sticker, at: 0)
        localStickerStore?.save(localStickers)
    }
}
