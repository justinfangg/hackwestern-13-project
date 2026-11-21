import Foundation
import FogCore

/// Fills gaps between consecutive accepted fixes so fast movement doesn't leave
/// uncleared holes in the fog (PRD F-4).
public enum PathInterpolator {
    /// Points every `spacing` metres from `from` (exclusive) to `to` (inclusive).
    /// Gaps longer than `maxGap` are not bridged (only `to` is returned) so a GPS
    /// dropout never clears a straight line through buildings.
    public static func points(from: Coordinate, to: Coordinate,
                              spacing: Double = 10, maxGap: Double = 150) -> [Coordinate] {
        let d = Geo.distance(from, to)
        guard d > spacing, d <= maxGap else { return [to] }
        let steps = Int((d / spacing).rounded(.up))
        return (1...steps).map { Geo.lerp(from, to, Double($0) / Double(steps)) }
    }
}
