import Foundation

/// The two hold commands the app sends a pane's bridge over its control FIFO.
///
/// `paddock.`-namespaced, not `terminal.`: the bridge forwards every
/// `terminal.*` line to herdr verbatim, so a hold command spelled that way
/// would be sent on to herdr instead of acted on here.
public enum HoldCommand: String, Equatable, Sendable, CaseIterable {
    /// Drop paddock's herdr control client for this pane. herdr removes the
    /// client, and with it the pane's `direct_attach_resize_lock`, so herdr's
    /// own shell clients size the pane again. The surface, its PTY and its
    /// scrollback are untouched.
    case release = "paddock.release_hold"
    /// Take the pane back: a new control client at the PTY's current size,
    /// which retakes the lock and answers with a full frame.
    case take = "paddock.take_hold"

    public var json: [String: Any] { ["type": rawValue] }
}

/// When paddock holds herdr's panes and when it hands them back, from the
/// app's active state alone.
///
/// herdr sizes a pane to whichever shell client is in front, but paddock is
/// not a shell client: it attaches per pane and herdr takes a
/// `direct_attach_resize_lock` that does not follow focus. Releasing while
/// paddock is not the active app is what puts the pane back under that rule.
///
/// Only the release is delayed. Retaking is immediate because the user is
/// looking at paddock by then, and a pane that is neither sized nor streaming
/// is visible for exactly as long as the retake is put off.
public struct HoldPolicy: Equatable, Sendable {
    /// How long paddock stays inactive before it hands the panes back.
    ///
    /// The cost of releasing too eagerly is a round trip, not a wasted
    /// message: herdr resizes every pane to the terminal's layout, then
    /// paddock's retake resizes them all back, and both reflows are visible
    /// to every client of the session. Twelve panes measured 204ms from the
    /// retake to their last full frame, so this is a shade over twice that:
    /// a Cmd+Tab bounce or a click through paddock cannot outrun the work it
    /// would cause, and a real switch to the terminal pays under half a
    /// second before the panes are its own size.
    public static let releaseDelay: TimeInterval = 0.4

    public enum Event: Equatable, Sendable {
        case becameActive
        case resignedActive
        /// The scheduled release came due.
        case releaseDeadline
    }

    public enum Effect: Equatable, Sendable {
        case none
        case scheduleRelease(after: TimeInterval)
        case cancelScheduledRelease
        /// Send every held pane `paddock.release_hold`.
        case release
        /// Send every held pane `paddock.take_hold`.
        case take
    }

    /// Whether paddock's bridges currently hold their panes. Starts true: a
    /// bridge takes its control client the moment it spawns.
    public private(set) var isHolding = true
    public private(set) var isReleaseScheduled = false

    public init() {}

    public mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .resignedActive:
            guard isHolding, !isReleaseScheduled else { return .none }
            isReleaseScheduled = true
            return .scheduleRelease(after: Self.releaseDelay)
        case .releaseDeadline:
            // A deadline that outlived its schedule (paddock became active
            // first) decides nothing: the cancel already happened.
            guard isReleaseScheduled else { return .none }
            isReleaseScheduled = false
            isHolding = false
            return .release
        case .becameActive:
            if isReleaseScheduled {
                isReleaseScheduled = false
                return .cancelScheduledRelease
            }
            guard !isHolding else { return .none }
            isHolding = true
            return .take
        }
    }
}
