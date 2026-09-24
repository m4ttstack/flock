import Foundation

/// When a pane's attach badge appears, and when it may stop showing once
/// herdr's first frame has arrived.
///
/// Two timers, and they answer different complaints. `appearDelay` is why a
/// fast attach shows nothing at all: the badge stays away unless the pane is
/// still waiting after it, so the common case is a pane that simply appears.
/// `minimumDisplay` is why a badge that does appear cannot flicker: once shown
/// it holds, even if the frame lands a moment later. The floor is a minimum,
/// never a ceiling -- a slow attach dismisses the instant its frame arrives,
/// with no extra delay on top.
public enum PaneLoaderPolicy {
    /// How long a pane may take to paint before it is worth saying anything.
    /// Under this, showing a badge is worse than showing nothing: the pane was
    /// always about to be there, and the badge is just something that flashed.
    ///
    /// An earlier version had no delay at all, so every attach announced
    /// itself, including the ones that finished in 80ms. That is what made the
    /// loader read as a toll booth on a pane that was already ready.
    public static let appearDelay: Duration = .milliseconds(200)

    /// Once the badge is up, the shortest time it stays. Long enough not to
    /// register as a flicker, short enough not to be a wait of its own.
    ///
    /// This used to be derived from the trail's loop length, so a dismissal
    /// landed on the moment the echoes reached full spread. That mattered when
    /// the loader owned the whole pane and a full gesture was the point. A
    /// corner badge is not watched, so the coupling bought nothing and cost
    /// every future change to the animation a change to the floor.
    public static let minimumDisplay: Duration = .milliseconds(400)

    /// How long the badge takes to fade, in and out. Seconds rather than
    /// `Duration` because SwiftUI's animation curves take a `Double`.
    public static let dismissCrossFade: Double = 0.1

    public static func dismissAt(
        shownAt: ContinuousClock.Instant,
        firstFrameAt: ContinuousClock.Instant,
        minimum: Duration = minimumDisplay
    ) -> ContinuousClock.Instant {
        max(shownAt.advanced(by: minimum), firstFrameAt)
    }

    /// Whether a pane still waiting at `elapsed` should say so. The badge is
    /// armed by a timer rather than by the first frame's absence, so this is
    /// the whole rule: still no frame, and past the delay.
    public static func showsBadge(hasFirstFrame: Bool, elapsed: Duration) -> Bool {
        !hasFirstFrame && elapsed >= appearDelay
    }

    /// Whether the live terminal surface is the thing on screen. It needs BOTH
    /// halves, and each one covers a case the other gets wrong:
    ///
    /// - `hasFirstFrame` alone reveals the terminal the instant its frame
    ///   lands, while the badge is still holding its floor.
    /// - `!badgeVisible` alone reveals it in the window before the cell has
    ///   decided anything at all. A cold pane's first render happens before the
    ///   first-frame observer runs, so "no badge yet" is not "no badge
    ///   coming", and libghostty has usually already painted real content by
    ///   then: the pane flashes a frame of live terminal, then the badge drops
    ///   in on top of it.
    ///
    /// A warm surface satisfies both immediately and never shows a badge.
    public static func showsTerminalSurface(hasFirstFrame: Bool, badgeVisible: Bool) -> Bool {
        hasFirstFrame && !badgeVisible
    }

    /// A fresh pane is both things at once: it has no first frame yet, and it
    /// is a pristine pane the launcher wants to offer harnesses on.
    ///
    /// They no longer collide on screen -- the badge is in a corner and the
    /// launcher holds the middle -- but a pane that has not painted has no
    /// shell ready to receive anything either, and the launcher's buttons
    /// work by sending the harness name as input. Offering a button that
    /// would type into nothing is the reason this still waits.
    ///
    /// It waits on the terminal being shown, not merely on the badge being
    /// down: inside the badge's appear delay the badge is down too, and
    /// buttons offered there vanish when it arrives and return when it goes.
    public static func showsLauncherOverlay(isPristineLauncherPane: Bool, hasFirstFrame: Bool, badgeVisible: Bool) -> Bool {
        isPristineLauncherPane && showsTerminalSurface(hasFirstFrame: hasFirstFrame, badgeVisible: badgeVisible)
    }

    /// Whether a pane shows the static status card instead of waiting on the
    /// badge. A pane with no surface yet is still mid-attach whenever the app
    /// can attach at all, and on a busy main actor that part of the wait can
    /// outlast the whole first-frame part, so it belongs to the badge too. The
    /// card is only for an app that has no terminal to give a pane.
    public static func showsStatusCard(hasSurface: Bool, attachesSurfaces: Bool) -> Bool {
        !hasSurface && !attachesSurfaces
    }
}
