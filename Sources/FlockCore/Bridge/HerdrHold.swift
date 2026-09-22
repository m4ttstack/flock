import Foundation

/// The two hold commands the app sends a pane's bridge over its control FIFO.
///
/// `flock.`-namespaced, not `terminal.`: the bridge forwards every
/// `terminal.*` line to herdr verbatim, so a hold command spelled that way
/// would be sent on to herdr instead of acted on here.
public enum HoldCommand: String, Equatable, Sendable, CaseIterable {
    /// Drop flock's herdr control client for this pane. herdr removes the
    /// client, and with it the pane's `direct_attach_resize_lock`, so herdr's
    /// own shell clients size the pane again. The surface, its PTY and its
    /// scrollback are untouched.
    case release = "flock.release_hold"
    /// Take the pane back: a new control client at the PTY's current size,
    /// which retakes the lock and answers with a full frame.
    case take = "flock.take_hold"

    public var json: [String: Any] { ["type": rawValue] }
}

/// What a bridge tells the app about its hold, on the status FIFO.
public enum HoldStatus: String, Equatable, Sendable, CaseIterable {
    /// Every retake herdr would accept has been tried and refused. The pane has
    /// no herdr client at all and no further attempt is pending, so the app
    /// shows its status card rather than a frame that is no longer live.
    case lost = "flock.hold_lost"
}

/// When flock holds herdr's panes and when it hands them back, from whether
/// flock is on screen at all.
///
/// herdr sizes a pane to whichever shell client is in front, but flock is
/// not a shell client: it attaches per pane and herdr takes a
/// `direct_attach_resize_lock` that does not follow focus. Releasing while
/// flock is off screen is what puts the pane back under that rule.
///
/// On screen is the question, not frontmost, because releasing a pane also
/// stops herdr streaming its frames: a released pane keeps showing the last
/// frame it was sent until the retake's full frame arrives. A flock window
/// the user can see has to go on holding while another app is in front, or
/// its panes read as live while they are minutes stale.
///
/// Only the release is delayed. Retaking is immediate because the user is
/// looking at flock by then, and a pane that is neither sized nor streaming
/// is visible for exactly as long as the retake is put off.
public struct HoldPolicy: Equatable, Sendable {
    /// How long flock stays off screen before it hands the panes back. Must
    /// outlast a full retake of every pane, so a flicker out of view and back
    /// cannot outrun the round trip it would cause, and stay short enough that
    /// a terminal taking flock's place on screen is not left waiting to be
    /// sized.
    public static let releaseDelay: TimeInterval = 0.4

    public enum Event: Equatable, Sendable {
        /// Flock is on screen again, or is the active app.
        case becameVisible
        /// Flock left the screen: hidden, miniaturized, on another Space, or
        /// fully covered, and not the active app either.
        case becameHidden
        /// The scheduled release came due.
        case releaseDeadline
    }

    public enum Effect: Equatable, Sendable {
        case none
        case scheduleRelease(after: TimeInterval)
        case cancelScheduledRelease
        /// Send every held pane `flock.release_hold`.
        case release
        /// Send every held pane `flock.take_hold`.
        case take
    }

    /// Whether flock's bridges currently hold their panes. Starts true: a
    /// bridge takes its control client the moment it spawns.
    public private(set) var isHolding = true
    public private(set) var isReleaseScheduled = false

    public init() {}

    public mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .becameHidden:
            guard isHolding, !isReleaseScheduled else { return .none }
            isReleaseScheduled = true
            return .scheduleRelease(after: Self.releaseDelay)
        case .releaseDeadline:
            // A deadline that outlived its schedule (flock came back into
            // view first) decides nothing: the cancel already happened.
            guard isReleaseScheduled else { return .none }
            isReleaseScheduled = false
            isHolding = false
            return .release
        case .becameVisible:
            // A cancel is the one edge that asserts nothing: no release was
            // sent, so every pane provably still holds and there is nothing a
            // take could heal.
            if isReleaseScheduled {
                isReleaseScheduled = false
                return .cancelScheduledRelease
            }
            // Asserted even when this policy believes it already holds. The
            // belief can be wrong in one direction: a command dropped on a
            // full FIFO leaves that pane released with no later edge to
            // correct it. A bridge that already holds ignores the repeat.
            isHolding = true
            return .take
        }
    }
}
