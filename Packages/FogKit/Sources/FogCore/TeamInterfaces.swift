import Foundation

// Interfaces implemented by teammates' code. FogKit depends only on these protocols,
// so each side can be built and tested independently and swapped in later.
// Each protocol has a mock/simple implementation in FogKit for use until the real one lands.

/// Implemented by Ayman's `ExplorationStore` (H3 tiles + fog).
/// FogKit calls this for every interpolated path point. Fog only clears where the user has been.
@MainActor
public protocol ExplorationClearing: AnyObject {
    /// Clears every tile within the vision radius (30 m) of each point.
    /// - Returns: only the tiles that were *newly* cleared by this call (empty if all were already clear).
    func clearTiles(around points: [Coordinate]) -> [TileID]

    /// Demo "Reset fog" (PRD D-6): forget every cleared tile.
    func resetAll()

    /// Number of tiles cleared on this device.
    var clearedTileCount: Int { get }

    /// Adds tiles restored from the server after a reinstall (docs/api.md D8). No animation needed,
    /// and FogKit doesn't sync them back. - Returns: how many were new on this device.
    @discardableResult
    func restore(tiles: [TileID]) -> Int
}

/// Implemented by Jonathan's `AuthService` (Supabase anonymous sign-in).
public protocol AuthTokenProviding: AnyObject, Sendable {
    /// The current Supabase access token (JWT). With `forceRefresh`, refresh the session first:
    /// FogKit asks for this once after any 401 and retries the request (docs/api.md §1).
    func accessToken(forceRefresh: Bool) async throws -> String
}

extension AuthTokenProviding {
    public func accessToken() async throws -> String { try await accessToken(forceRefresh: false) }
}
