import Foundation
import Observation
import FogCore

/// Offline-first upload queue for cleared tiles, GPS pings and expeditions (PRD F-3, docs/api.md §2).
///
/// Everything is appended locally first and persisted to disk, then sent to `sync` in batches every
/// 30 s and when an expedition ends. Sync is idempotent, so resending after a failure is safe.
/// Rules from the contract:
/// - at most 5000 tiles, 2000 pings and 50 expeditions per request, oldest first;
/// - every batch with pings for an expedition also carries that expedition's current record
///   (the running one comes from `activeExpedition`).
@MainActor
@Observable
public final class SyncQueue {
    public struct Pending: Codable, Sendable {
        public var tiles: [TileClear] = []
        public var pings: [LocationPing] = []
        /// Ended expeditions not yet acknowledged, kept until their last ping has been sent.
        public var expeditions: [UUID: ExpeditionRecord] = [:]
    }

    public private(set) var pending: Pending
    public private(set) var isSyncing = false
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastError: String?
    /// Total tiles the server has for this user, from the last successful sync.
    public private(set) var serverTotalTiles: Int?
    public var pendingCount: Int { pending.tiles.count + pending.pings.count + pending.expeditions.count }

    public var interval: TimeInterval = 30
    public var maxTilesPerBatch = SyncRequest.maxTiles
    public var maxPingsPerBatch = SyncRequest.maxPings
    public var maxExpeditionsPerBatch = SyncRequest.maxExpeditions

    /// The running expedition's current record (`endedAt == nil`). Set by FogServices.
    @ObservationIgnored public var activeExpedition: (() -> ExpeditionRecord?)?

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
        pending.tiles += tiles.map { TileClear(h3: $0, clearedAt: date) }
        persist()
    }

    public func enqueue(ping: LocationPing) {
        pending.pings.append(ping)
        persist()
    }

    /// Queue an ended expedition's final record.
    public func enqueue(expedition: ExpeditionSummary) {
        let record = ExpeditionRecord(expedition)
        pending.expeditions[record.id] = record
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

        while !pending.tiles.isEmpty || !pending.pings.isEmpty || !pending.expeditions.isEmpty {
            let tiles = Array(pending.tiles.prefix(maxTilesPerBatch))
            let pings = Array(pending.pings.prefix(maxPingsPerBatch))
            let expeditions = expeditionRecords(for: pings)

            let response: SyncResponse
            do {
                response = try await api.sync(SyncRequest(expeditions: expeditions, pings: pings, tiles: tiles))
            } catch {
                lastError = String(describing: error)
                return // keep everything; retry next tick
            }

            // Items enqueued during the request were appended after these, so drop from the front.
            pending.tiles.removeFirst(tiles.count)
            pending.pings.removeFirst(pings.count)
            let stillReferenced = Set(pending.pings.compactMap(\.expeditionID))
            for record in expeditions where record.endedAt != nil && !stillReferenced.contains(record.id) {
                pending.expeditions[record.id] = nil
            }
            persist()
            serverTotalTiles = response.totalTiles
            lastError = nil
            lastSyncedAt = Date()
        }
    }

    /// Records for every expedition the pings mention, plus queued ended expeditions, up to the limit.
    private func expeditionRecords(for pings: [LocationPing]) -> [ExpeditionRecord] {
        let active = activeExpedition?()
        var result: [UUID: ExpeditionRecord] = [:]
        for id in Set(pings.compactMap(\.expeditionID)) {
            if let r = pending.expeditions[id] ?? (active?.id == id ? active : nil) { result[id] = r }
        }
        for (id, r) in pending.expeditions.sorted(by: { $0.value.startedAt < $1.value.startedAt })
        where result.count < maxExpeditionsPerBatch && result[id] == nil {
            result[id] = r
        }
        return result.values.sorted { $0.startedAt < $1.startedAt }
    }

    private func persist() { store?.save(pending) }
}
