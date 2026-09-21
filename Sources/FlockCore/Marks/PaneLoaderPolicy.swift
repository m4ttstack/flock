import Foundation

/// When a pane's attach loader may stop showing, once herdr's first frame
/// has actually arrived. The floor is a minimum, never a ceiling: a fast
/// attach still holds until `shownAt + minimum`, but a slow one dismisses
/// the instant its frame arrives, with no extra delay added on top.
public enum PaneLoaderPolicy {
    /// How long the loader takes to cross-fade into the live terminal.
    /// Seconds rather than `Duration` because SwiftUI's animation curves
    /// take a `Double` and there is one consumer.
    public static let dismissCrossFade: Double = 0.15

    /// Half a cross-fade short of one whole trail loop, so the fade straddles
    /// the moment the echoes reach full spread rather than beginning there.
    /// Beginning there means the trail visibly starts gathering again
    /// underneath the fade; straddling it means the last thing on screen is
    /// the trail at its widest.
    ///
    /// Derived rather than written out so it cannot silently stop lining up
    /// when the choreography changes. `PaneLoaderPolicyTests` asserts what
    /// this works out to today.
    ///
    /// Rounded to whole milliseconds: built straight from the `Double` it
    /// lands an attosecond or so off the same value spelled literally, which
    /// is invisible on screen and maddening in an equality assertion.
    public static let minimumDisplay: Duration = .milliseconds(
        Int(((PaneLoaderChoreography.loopDuration - dismissCrossFade / 2) * 1000).rounded())
    )

    public static func dismissAt(
        shownAt: ContinuousClock.Instant,
        firstFrameAt: ContinuousClock.Instant,
        minimum: Duration = minimumDisplay
    ) -> ContinuousClock.Instant {
        max(shownAt.advanced(by: minimum), firstFrameAt)
    }
}
