import Foundation
import Observation
import FogCore

/// The social feed (docs/api.md §8): everyone's finished sessions, newest first, loaded a page at
/// a time. The social page reads `posts`; calls `refresh()` on appear / pull to refresh and
/// `loadMoreIfNeeded(after:)` as rows scroll into view.
@MainActor
@Observable
public final class FeedModel {
    public private(set) var posts: [FeedPost] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = true
    public private(set) var lastError: String?
    /// True once the first page has loaded (or failed), so the page can tell "empty" from "not yet".
    public private(set) var hasLoaded = false

    @ObservationIgnored private let api: FogAPI
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var nextBefore: Date?
    /// Bumped by `refresh()` so a slow older page can't land on top of a fresh first page.
    @ObservationIgnored private var generation = 0

    public init(api: FogAPI, pageSize: Int = 20) {
        self.api = api
        self.pageSize = pageSize
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
            posts = page.posts
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
            let known = Set(posts.map(\.id))
            posts += page.posts.filter { !known.contains($0.id) }
            nextBefore = page.nextBefore
            hasMore = page.nextBefore != nil
        } catch {
            // Leave hasMore on; the next row that appears tries again.
        }
    }
}
