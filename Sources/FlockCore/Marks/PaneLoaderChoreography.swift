import Foundation

/// The trail's own loop: each echo gathers into the leader, holds a beat
/// merged, then drifts back apart, staggered by `HerdrRamTrail.staggerDelay`
/// per echo. Pure and clock-free so the stagger and the easing shape are
/// testable without driving an animation.
public enum PaneLoaderChoreography {
    public static let gatherDuration: Double = 0.32
    public static let holdDuration: Double = 0.18
    public static let driftDuration: Double = 0.55
    /// One whole gather-hold-release. `PaneLoaderPolicy.minimumDisplay` is
    /// derived from this so the loader's dismissal lands on the end of a
    /// loop, where the trail is at full spread; changing any of the three
    /// phases above moves the floor with it by design.
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
