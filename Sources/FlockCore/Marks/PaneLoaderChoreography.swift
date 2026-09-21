import Foundation

/// The trail's own loop: each echo gathers into the leader, holds a beat
/// merged, then drifts back apart, staggered by `HerdrRamTrail.staggerDelay`
/// per echo. Pure and clock-free so the stagger and the easing shape are
/// testable without driving an animation.
public enum PaneLoaderChoreography {
    public static let gatherDuration: Double = 0.45
    public static let holdDuration: Double = 0.25
    public static let driftDuration: Double = 0.8
    /// Sized to land inside `PaneLoaderPolicy.minimumDisplay`, so the window
    /// the loader is guaranteed to be on screen for always contains one whole
    /// gesture. Move the floor and this has to move with it, or the drift
    /// apart gets cut off mid-release on every fast attach.
    public static let loopDuration = gatherDuration + holdDuration + driftDuration

    /// How much opacity an echo gives up as it reaches the merge, regained
    /// on the way back out -- as if the leader briefly absorbed it.
    public static let mergeOpacityDrop: Double = 0.1

    /// How merged an echo is at `elapsed` seconds into the shared loop
    /// clock, after `startDelay`: 0 is fully separated (rest), 1 is merged
    /// with the leader. Ease-out gathering is what makes the approach read
    /// as arriving rather than snapping; ease-in-out drifting apart is what
    /// keeps the release from reading as a bounce.
    public static func mergeProgress(elapsed: Double, startDelay: Double) -> Double {
        let local = wrapped(elapsed - startDelay, into: loopDuration)
        if local < gatherDuration {
            return easeOut(local / gatherDuration)
        }
        if local < gatherDuration + holdDuration {
            return 1
        }
        let driftElapsed = local - gatherDuration - holdDuration
        return 1 - easeInOut(driftElapsed / driftDuration)
    }

    /// Positive modulo: `elapsed` can be negative once a stagger delay is
    /// subtracted from an early sample, and Swift's `%` keeps the sign of
    /// its left operand rather than wrapping it forward.
    private static func wrapped(_ value: Double, into period: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }

    private static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
