import UIKit

/// Presentation-only styles understood by the fog renderer.
enum FogRevealStyle: Sendable, Equatable {
    case normal
}

/// Centralizes the map module's visual constants without creating an app-wide
/// design-system dependency. Values are intentionally subtle enough that the
/// real MapKit geography remains the reward for exploration.
struct FogAppearance {
    let baseFogColor: UIColor
    let tealGlowColor: UIColor
    let questMarkerColor: UIColor

    let minimumClearEdgeLength: CGFloat
    let clearMaskRadiusScale: CGFloat
    let revealBloomRadiusScale: CGFloat

    let primaryTextureTileSize: CGFloat
    let secondaryTextureTileSize: CGFloat
    let primaryTextureOpacity: CGFloat
    let secondaryTextureOpacity: CGFloat
    let primaryDriftVelocity: CGPoint
    let secondaryDriftVelocity: CGPoint
    let atmosphericFramesPerSecond: Double

    let normalRevealDuration: TimeInterval
    let normalMaximumStagger: TimeInterval

    static let `default` = FogAppearance(
        baseFogColor: UIColor(
            red: 21.0 / 255.0,
            green: 29.0 / 255.0,
            blue: 41.0 / 255.0,
            alpha: 0.62
        ),
        tealGlowColor: UIColor(
            red: 48.0 / 255.0,
            green: 224.0 / 255.0,
            blue: 201.0 / 255.0,
            alpha: 1
        ),
        questMarkerColor: UIColor(
            red: 246.0 / 255.0,
            green: 190.0 / 255.0,
            blue: 70.0 / 255.0,
            alpha: 1
        ),
        minimumClearEdgeLength: 0.65,
        clearMaskRadiusScale: 1.5,
        revealBloomRadiusScale: 1.9,
        primaryTextureTileSize: 420,
        secondaryTextureTileSize: 690,
        primaryTextureOpacity: 0.66,
        secondaryTextureOpacity: 0.48,
        primaryDriftVelocity: CGPoint(x: 0.34, y: 0.11),
        secondaryDriftVelocity: CGPoint(x: -0.16, y: 0.23),
        atmosphericFramesPerSecond: 8,
        normalRevealDuration: 0.78,
        normalMaximumStagger: 0.11
    )
}
