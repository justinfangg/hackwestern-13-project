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
}

/// Implemented by Jonathan's `AuthService` (Supabase anonymous sign-in).
public protocol AuthTokenProviding: AnyObject, Sendable {
    /// A valid Supabase access token (JWT), refreshed if needed.
    func accessToken() async throws -> String
    /// Supabase user id of the signed-in user, if any.
    var currentUserID: UUID? { get async }
}
