import Foundation

/// The attach badge's run along the bottom of a pane: the mark ambles right
/// to left, the way the ram faces, bouncing as it goes along a gently winding
/// path, and drops a trail of dots off its back that fades behind it, a
/// little goat trail. Pure and clock-free, like `PaneLoaderChoreography`, so
/// the path is testable without an animation.
public enum PaneLoaderStride {
    /// Points per second. Slow on purpose: the hops carry the liveliness.
    public static let speed: Double = 50
    /// One hop, ground to ground. Quick against the slow travel, so the mark
    /// bounces more than it leaps.
    public static let hopDuration: Double = 0.42
    /// How high a hop lifts, as a fraction of the mark's size. The mark hops
    /// as one piece: its echoes already trail up and behind the leader, so
    /// lifting the leader alone runs it into them and the ram turns to a blob.
    public static let hopHeightFraction: Double = 0.45
    /// Points travelled between one dropped dot and the next.
    public static let dotSpacing: Double = 7
    /// Dots still on the ground; the oldest is nearly faded out.
    public static let trailLength = 16
    /// How far the path rises and falls either side of the ground line.
    public static let windAmplitude: Double = 5
    /// One full rise and fall of the path, in points.
    public static let windWavelength: Double = 90
    /// How far past each edge the badge runs before it wraps, so it leaves
    /// and re-enters beyond the pane's own padding rather than popping inside
    /// it.
    public static let overscan: Double = 24

    /// One dot of the trail.
    public struct TrailDot: Equatable, Sendable {
        /// Where it was dropped, in the same x as `leadingX`.
        public let x: Double
        /// Its height on the path at `x`, up positive.
        public let lift: Double
        /// 1 the instant it drops, falling toward 0 over `trailLength` dots.
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

    /// The path's height at `x`, up positive. Keyed on where a point is
    /// rather than when, so a dot keeps its height after it drops and the ram
    /// walks the same curve its trail lies on.
    public static func winding(atX x: Double) -> Double {
        windAmplitude * sin(2 * .pi * x / windWavelength)
    }

    /// Every dot not yet faded, newest first. One drops every `dotSpacing`
    /// points of travel, the first at `elapsed` 0, each `tailOffset` behind
    /// the badge's leading edge where it was at the time, and stays put while
    /// the mark moves on.
    public static func trail(
        elapsed: Double, start: Double, badgeWidth: Double, boxWidth: Double, tailOffset: Double
    ) -> [TrailDot] {
        guard elapsed >= 0 else { return [] }
        let interval = dotSpacing / speed
        let newest = Int((elapsed / interval).rounded(.down))
        let fadeSpan = Double(trailLength) * interval
        return (max(0, newest - trailLength + 1)...newest).reversed().map { drop in
            let droppedAt = Double(drop) * interval
            let x = leadingX(elapsed: droppedAt, start: start, badgeWidth: badgeWidth, boxWidth: boxWidth) + tailOffset
            return TrailDot(x: x, lift: winding(atX: x), opacity: 1 - (elapsed - droppedAt) / fadeSpan)
        }
    }

    private static func wrapped(_ value: Double, into period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}
