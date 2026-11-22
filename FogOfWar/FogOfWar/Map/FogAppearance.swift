import UIKit

/// Presentation-only styles understood by the fog renderer.
nonisolated enum FogRevealStyle: Sendable, Equatable {
    case normal
}

/// Centralizes the map module's visual constants without creating an app-wide
/// design-system dependency.
nonisolated struct FogAppearance: Sendable {
    /// Grey haze painted under the fog banks so thin patches between banks
    /// still read as "unexplored".
    let baseFogColor: UIColor

    let minimumClearEdgeLength: CGFloat
    let clearMaskRadiusScale: CGFloat

    let normalRevealDuration: TimeInterval
    let normalMaximumStagger: TimeInterval

    /// In-place fade of fog the player walks into (see `CloudDispersalView`).
    let dispersalFadeDuration: TimeInterval
    let dispersalMaximumStagger: TimeInterval

    static let `default` = FogAppearance(
        baseFogColor: UIColor(red: 0.84, green: 0.84, blue: 0.83, alpha: 0.68),
        minimumClearEdgeLength: 0.65,
        clearMaskRadiusScale: 1.5,
        normalRevealDuration: 0.9,
        normalMaximumStagger: 0.14,
        dispersalFadeDuration: 1.3,
        dispersalMaximumStagger: 0.25
    )
}
