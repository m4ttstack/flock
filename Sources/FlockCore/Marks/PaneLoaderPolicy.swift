import Foundation

/// When a pane's attach loader may stop showing, once herdr's first frame
/// has actually arrived. The floor is a minimum, never a ceiling: a fast
/// attach still holds until `shownAt + minimum`, but a slow one dismisses
/// the instant its frame arrives, with no extra delay added on top.
public enum PaneLoaderPolicy {
    public static let minimumDisplay: Duration = .milliseconds(2000)

    public static func dismissAt(
        shownAt: ContinuousClock.Instant,
        firstFrameAt: ContinuousClock.Instant,
        minimum: Duration = minimumDisplay
    ) -> ContinuousClock.Instant {
        max(shownAt.advanced(by: minimum), firstFrameAt)
    }
}
