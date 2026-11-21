import SwiftUI

/// Sheet-style drag physics shared by the map/profile split and the Quests sheet.
///
/// Dragging follows the finger 1:1 inside the allowed range and rubber-bands
/// beyond it (the same curve `UIScrollView` uses). On release the gesture's
/// velocity is projected forward to pick a detent, and the snap is driven by a
/// SwiftUI spring that starts with the finger's velocity, so a flick carries
/// straight into the settle instead of restarting from rest.
enum SpringDetents {
    /// UIScrollView-style resistance once a value is dragged past `range`.
    static func rubberBanded(
        _ value: CGFloat,
        in range: ClosedRange<CGFloat>,
        dimension: CGFloat,
        coefficient: CGFloat = 0.55
    ) -> CGFloat {
        guard dimension > 0 else { return min(max(value, range.lowerBound), range.upperBound) }
        if value < range.lowerBound {
            let overshoot = range.lowerBound - value
            return range.lowerBound - band(overshoot, dimension: dimension, coefficient: coefficient)
        }
        if value > range.upperBound {
            let overshoot = value - range.upperBound
            return range.upperBound + band(overshoot, dimension: dimension, coefficient: coefficient)
        }
        return value
    }

    /// Picks the detent nearest to where the gesture would come to rest.
    /// A decisive flick always advances at least one detent in its direction.
    static func target(
        from current: CGFloat,
        velocity: CGFloat,
        detents: [CGFloat]
    ) -> CGFloat {
        let sorted = detents.sorted()
        guard let first = sorted.first else { return current }

        // Deceleration close to a sheet's: roughly 0.2s of momentum.
        let projected = current + velocity * 0.2
        var best = first
        for detent in sorted where abs(detent - projected) < abs(best - projected) {
            best = detent
        }

        let flickThreshold: CGFloat = 450
        if velocity > flickThreshold, best <= current + 1,
           let next = sorted.first(where: { $0 > current + 1 }) {
            best = next
        } else if velocity < -flickThreshold, best >= current - 1,
                  let previous = sorted.last(where: { $0 < current - 1 }) {
            best = previous
        }
        return best
    }

    /// A slightly bouncy spring (close to a system sheet) seeded with the
    /// release velocity. SwiftUI expects that velocity relative to the
    /// remaining distance, so it is normalised here.
    static func snapAnimation(
        from current: CGFloat,
        to target: CGFloat,
        velocity: CGFloat
    ) -> Animation {
        let distance = target - current
        var relativeVelocity: Double = 0
        if abs(distance) > 0.5 {
            relativeVelocity = Double(velocity / distance)
            relativeVelocity = min(max(relativeVelocity, -12), 12)
        }
        return .interpolatingSpring(duration: 0.46, bounce: 0.16, initialVelocity: relativeVelocity)
    }

    private static func band(_ overshoot: CGFloat, dimension: CGFloat, coefficient: CGFloat) -> CGFloat {
        (1 - 1 / (overshoot * coefficient / dimension + 1)) * dimension
    }
}
