import Foundation
import Observation
import FogCore

/// The social feed (docs/api.md §8): everyone's finished sessions, newest first, loaded a page at
/// a time. The social page reads `posts`; calls `refresh()` on appear / pull to refresh and
/// `loadMoreIfNeeded(after:)` as rows scroll into view.
@MainActor
@Observable
public final class FeedModel {
    /// Everyone's posts, newest first: the server's, plus this device's local-only posts (Demo mode).
    public var posts: [FeedPost] {
        guard !localPosts.isEmpty else { return serverPosts }
        let serverIDs = Set(serverPosts.map(\.id))
        return (serverPosts + localPosts.filter { !serverIDs.contains($0.id) })
            .sorted { $0.endedAt > $1.endedAt }
    }
    /// Pages loaded from the server.
    public private(set) var serverPosts: [FeedPost] = []
    /// Sessions that were never sent to the server (Demo mode), shown only on this device.
    public private(set) var localPosts: [FeedPost] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = true
    public private(set) var lastError: String?
    /// True once the first page has loaded (or failed), so the page can tell "empty" from "not yet".
    public private(set) var hasLoaded = false

    @ObservationIgnored private let api: FogAPI
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let localStore: JSONFileStore<[FeedPost]>?
    @ObservationIgnored private var nextBefore: Date?
    /// Bumped by `refresh()` so a slow older page can't land on top of a fresh first page.
    @ObservationIgnored private var generation = 0

    public init(api: FogAPI, pageSize: Int = 20, localStore: JSONFileStore<[FeedPost]>? = nil) {
        self.api = api
        self.pageSize = pageSize
        self.localStore = localStore
        localPosts = (localStore?.load() ?? []).map { Self.relocated($0, store: localStore) }
    }

    /// The app's container path can change between installs, so a saved sticker file is re-pointed
    /// at the same file name in the current sticker folder (Application Support/FogOfWar/stickers).
    private static func relocated(_ post: FeedPost, store: JSONFileStore<[FeedPost]>?) -> FeedPost {
        guard let store, let url = post.sticker?.url, url.isFileURL,
              !FileManager.default.fileExists(atPath: url.path) else { return post }
        let current = store.url.deletingLastPathComponent()
            .appendingPathComponent("stickers", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        guard FileManager.default.fileExists(atPath: current.path) else { return post }
        var post = post
        post.sticker?.url = current
        return post
    }

    /// Adds a post that only this device shows (kept across launches); newest first.
    public func addLocalPost(_ post: FeedPost) {
        localPosts.removeAll { $0.id == post.id }
        localPosts.insert(post, at: 0)
        localStore?.save(localPosts)
    }

    /// Reloads the first page.
    public func refresh() async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await api.feed(before: nil, limit: pageSize)
            guard gen == generation else { return }
            serverPosts = page.posts
            nextBefore = page.nextBefore
            hasMore = page.nextBefore != nil
            lastError = nil
        } catch {
            guard gen == generation else { return }
            lastError = String(describing: error)
        }
        hasLoaded = true
    }

    /// Loads the next page when `post` is one of the last few rows.
    public func loadMoreIfNeeded(after post: FeedPost) async {
        guard hasMore, !isLoading, !isLoadingMore, let before = nextBefore,
              let index = posts.firstIndex(where: { $0.id == post.id }),
              index >= posts.count - 3 else { return }
        let gen = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.feed(before: before, limit: pageSize)
            guard gen == generation else { return }
            let known = Set(serverPosts.map(\.id))
            serverPosts += page.posts.filter { !known.contains($0.id) }
            nextBefore = page.nextBefore
            hasMore = page.nextBefore != nil
        } catch {
            // Leave hasMore on; the next row that appears tries again.
        }
    }
}

extension FeedPost {
    /// A post for a session that stays on this device (Demo mode), shaped like the feed endpoint's.
    /// `stickerFile` is the sticker's local PNG, if a quest was found.
    public static func local(id: UUID, author: Author, startedAt: Date, endedAt: Date, distanceM: Double,
                             newTiles: Int, segments: [[Coordinate]], sticker: Find?) -> FeedPost {
        FeedPost(id: id, author: author, startedAt: startedAt, endedAt: endedAt,
                 durationS: max(0, Int(endedAt.timeIntervalSince(startedAt))), distanceM: distanceM,
                 newTiles: newTiles, area: nil, sticker: sticker,
                 routeShape: routeShape(segments.flatMap { $0 }))
    }

    /// Same as the feed endpoint's `routeShape` (supabase/functions/feed): projected flat, north up,
    /// longer side spanning 0…1, centred, at most 80 points. No position survives.
    static func routeShape(_ points: [Coordinate]) -> [ShapePoint]? {
        guard points.count >= 2 else { return nil }
        let lat0 = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let k = cos(lat0 * .pi / 180)
        let flat = points.map { (x: $0.longitude * k, y: -$0.latitude) }
        let xs = flat.map(\.x), ys = flat.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let span = max(maxX - minX, maxY - minY)
        guard span > 0 else { return nil }
        let padX = (1 - (maxX - minX) / span) / 2, padY = (1 - (maxY - minY) / span) / 2
        let count = min(flat.count, 80)
        return (0 ..< count).map { i in
            let p = flat[Int((Double(i * (flat.count - 1)) / Double(count - 1)).rounded())]
            return ShapePoint(x: padX + (p.x - minX) / span, y: padY + (p.y - minY) / span)
        }
    }
}
