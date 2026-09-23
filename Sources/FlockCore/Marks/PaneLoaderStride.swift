import Foundation

/// The attach badge's run along the bottom of a pane: the mark ambles right
/// to left, the way the ram faces, bouncing as it goes and leaving a dot on
/// the ground at every landing, a little goat trail that fades behind it.
/// Pure and clock-free, like `PaneLoaderChoreography`, so the path is
/// testable without an animation.
public enum PaneLoaderStride {
    /// Points per second. Slow on purpose: the hops carry the liveliness, and
    /// the distance per hop is what spaces the trail.
    public static let speed: Double = 50
    /// One hop, ground to ground. Quick against the slow travel, so the mark
    /// bounces more than it leaps.
    public static let hopDuration: Double = 0.42
    /// How high a hop lifts, as a fraction of the mark's size. The mark hops
    /// as one piece: its echoes already trail up and behind the leader, so
    /// lifting the leader alone runs it into them and the ram turns to a blob.
    public static let hopHeightFraction: Double = 0.45
    /// Landings still marked on the ground; the oldest is nearly faded out.
    public static let trailLength = 6
    /// How far past each edge the badge runs before it wraps, so it leaves
    /// and re-enters beyond the pane's own padding rather than popping inside
    /// it.
    public static let overscan: Double = 24

    /// One landing's mark on the ground.
    public struct Hoofprint: Equatable, Sendable {
        /// The badge's leading edge when it landed there, in the same x as
        /// `leadingX`.
        public let leadingX: Double
        /// 1 the instant it lands, falling toward 0 over `trailLength` hops.
        public let opacity: Double
    }

    /// The badge's leading edge at `elapsed`, in the travel box's own x. It
    /// starts at `start`, runs left until fully past the left edge, then comes
    /// back in from beyond the right one.
    public static func leadingX(elapsed: Double, start: Double, badgeWidth: Double, boxWidth: Double) -> Double {
        let entry = boxWidth + overscan
        let lap = boxWidth + badgeWidth + 2 * overscan
        guard lap > 0 else { return start }
        return entry - wrapped(entry - start + speed * elapsed, into: lap)
    }

    /// How far off the ground the mark is at `elapsed`, 0 landed and 1 at
    /// the top of its hop. A rectified sine: a hard landing and a rounded
    /// top, which is what makes it read as a bounce.
    public static func hopLift(elapsed: Double) -> Double {
        abs(sin(.pi * elapsed / hopDuration))
    }

    /// Every landing that has not yet faded, newest first. The mark is on the
    /// ground at every whole multiple of `hopDuration`, the first at `elapsed`
    /// 0, and each print stays where it was made while the mark moves on.
    public static func hoofprints(elapsed: Double, start: Double, badgeWidth: Double, boxWidth: Double) -> [Hoofprint] {
        guard elapsed >= 0 else { return [] }
        let newest = Int((elapsed / hopDuration).rounded(.down))
        let fadeSpan = Double(trailLength) * hopDuration
        return (max(0, newest - trailLength + 1)...newest).reversed().map { landing in
            let landedAt = Double(landing) * hopDuration
            return Hoofprint(
                leadingX: leadingX(elapsed: landedAt, start: start, badgeWidth: badgeWidth, boxWidth: boxWidth),
                opacity: 1 - (elapsed - landedAt) / fadeSpan
            )
        }
    }

    private static func wrapped(_ value: Double, into period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}
