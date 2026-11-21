import Foundation
import Observation
import FogCore

/// Offline-first upload queue for cleared tiles, GPS pings and expeditions (PRD F-3).
///
/// Everything is appended locally first and persisted to disk, then sent to the `sync`
/// Edge Function in batches every 30 s and when an expedition ends. Sync is upsert-only,
/// so resending after a failure is safe. Batching keeps the number of Edge Function calls and database connections low.
@MainActor
@Observable
public final class SyncQueue {
    public struct Pending: Codable, Sendable {
        public var tiles: [TileClear] = []
        public var pings: [LocationPing] = []
        public var expeditions: [ExpeditionRecord] = []
    }

    public private(set) var pending: Pending
    public private(set) var isSyncing = false
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastError: String?
    public var pendingCount: Int { pending.tiles.count + pending.pings.count + pending.expeditions.count }

    public var interval: TimeInterval = 30
    public var maxTilesPerBatch = 2_000
    public var maxPingsPerBatch = 3_000

    @ObservationIgnored private let api: FogAPI
    @ObservationIgnored private let store: JSONFileStore<Pending>?
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// - Parameter store: where to persist pending items; nil keeps them in memory only (tests).
    public init(api: FogAPI, store: JSONFileStore<Pending>? = JSONFileStore(filename: "pending-sync.json")) {
        self.api = api
        self.store = store
        self.pending = store?.load() ?? Pending()
    }

    public func enqueue(tiles: [TileID], at date: Date = Date()) {
        guard !tiles.isEmpty else { return }
        pending.tiles += tiles.map { TileClear(tile: $0, clearedAt: date) }
        persist()
    }

    public func enqueue(ping: LocationPing) {
        pending.pings.append(ping)
        persist()
    }

    public func enqueue(expedition: ExpeditionSummary) {
        pending.expeditions.append(ExpeditionRecord(expedition))
        persist()
    }

    /// Start periodic flushing.
    public func startAutoSync() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: .seconds(interval))
                await self?.flush()
            }
        }
    }

    public func stopAutoSync() {
        timer?.cancel()
        timer = nil
    }

    /// Sends everything pending, in batches. Safe to call any time; concurrent calls are ignored.
    public func flush() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        while pendingCount > 0 {
            let tiles = Array(pending.tiles.prefix(maxTilesPerBatch))
            let pings = Array(pending.pings.prefix(maxPingsPerBatch))
            let expeditions = pending.expeditions
            do {
                _ = try await api.sync(SyncRequest(tiles: tiles, pings: pings, expeditions: expeditions))
            } catch {
                lastError = String(describing: error)
                return // keep everything; retry next tick
            }
            // Items enqueued during the request were appended after these, so drop from the front.
            pending.tiles.removeFirst(tiles.count)
            pending.pings.removeFirst(pings.count)
            pending.expeditions.removeFirst(expeditions.count)
            persist()
            lastError = nil
            lastSyncedAt = Date()
        }
    }

    private func persist() { store?.save(pending) }
}
