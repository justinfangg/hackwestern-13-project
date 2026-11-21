import UIKit

/// Presentation-only styles understood by the fog renderer.
nonisolated enum FogRevealStyle: Sendable, Equatable {
    case normal
}

/// Centralizes the map module's visual constants without creating an app-wide
/// design-system dependency.
nonisolated struct FogAppearance: Sendable {
    /// Light haze painted under the cloud puffs so gaps between clouds still
    /// read as "unexplored" (the Figma frame washes the whole map out).
    let baseFogColor: UIColor

    let minimumClearEdgeLength: CGFloat
    let clearMaskRadiusScale: CGFloat

    let normalRevealDuration: TimeInterval
    let normalMaximumStagger: TimeInterval

    /// Cloud push-away animation (see `CloudDispersalView`).
    let dispersalPushDuration: TimeInterval
    let dispersalFadeDelay: TimeInterval
    let dispersalFadeDuration: TimeInterval

    static let `default` = FogAppearance(
        baseFogColor: UIColor(red: 0.925, green: 0.925, blue: 0.918, alpha: 0.42),
        minimumClearEdgeLength: 0.65,
        clearMaskRadiusScale: 1.5,
        normalRevealDuration: 0.9,
        normalMaximumStagger: 0.14,
        dispersalPushDuration: 1.1,
        dispersalFadeDelay: 0.18,
        dispersalFadeDuration: 1.5
    )
}
