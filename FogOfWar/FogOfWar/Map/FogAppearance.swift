import UIKit

/// Presentation-only styles understood by the fog renderer.
nonisolated enum FogRevealStyle: Sendable, Equatable {
    case normal
}

/// Centralizes the map module's visual constants without creating an app-wide
/// design-system dependency. Jonathan can tune fog coverage from
/// `baseFogOpacity` / `baseFogColor` without touching renderer code.
nonisolated struct FogAppearance: Sendable {
    /// Primary wash over unexplored map. Keep this high enough that street names
    /// and building footprints are meaningfully obscured; lower it if the map
    /// feels too dark. Jonathan owns the final look.
    let baseFogOpacity: CGFloat
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
    /// Atmospheric redraw cadence. Drift is sub-point-per-frame, so a modest rate
    /// is enough; higher values cost a full visible-rect redraw plus per-cell clears.
    let atmosphericFramesPerSecond: Double

    let normalRevealDuration: TimeInterval
    let normalMaximumStagger: TimeInterval

    static let `default` = FogAppearance(
        // Was 0.62 after the first integration PR — streets stayed too readable.
        baseFogOpacity: 0.84,
        baseFogColor: UIColor(
            red: 18.0 / 255.0,
            green: 24.0 / 255.0,
            blue: 34.0 / 255.0,
            alpha: 0.84
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
        primaryTextureOpacity: 0.72,
        secondaryTextureOpacity: 0.52,
        primaryDriftVelocity: CGPoint(x: 0.34, y: 0.11),
        secondaryDriftVelocity: CGPoint(x: -0.16, y: 0.23),
        // 4 fps is enough for the current sub-pixel drift and halves atmospheric
        // full-viewport redraws versus the previous 8 fps. Physical-device cost of
        // the per-cell clear pass still needs Instruments on a real iPhone.
        atmosphericFramesPerSecond: 4,
        normalRevealDuration: 0.78,
        normalMaximumStagger: 0.11
    )
}
