import Foundation

/// The attach badge's run along the bottom of a pane: the whole badge slides
/// right to left at a steady speed, the way the ram faces, while the mark
/// bounces along above the caption. Pure and clock-free, like
/// `PaneLoaderChoreography`, so the path is testable without an animation.
public enum PaneLoaderStride {
    /// Points per second. Most badges are up for well under a second, so this
    /// has to cover visible ground in that time, and still read as a trot on a
    /// wide pane that takes several seconds to cross.
    public static let speed: Double = 140
    /// One hop, ground to ground.
    public static let hopDuration: Double = 0.42
    /// How high a hop lifts, as a fraction of the mark's size. The mark hops
    /// as one piece: its echoes already trail up and behind the leader, so
    /// lifting the leader alone runs it into them and the ram turns to a blob.
    public static let hopHeightFraction: Double = 0.3
    /// How far past each edge the badge runs before it wraps, so it leaves
    /// and re-enters beyond the pane's own padding rather than popping inside
    /// it.
    public static let overscan: Double = 24

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

    private static func wrapped(_ value: Double, into period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}
