import Foundation

/// Decides which panes may be offered the harness launcher, and when.
///
/// Two things make a pane offerable, and the second is why this is not just
/// provenance: flock created it (a fresh pane, nothing in it yet), or the user
/// cleared it (they asked for a blank pane, whoever made it). Either way the
/// offer goes away as soon as the pane is in use -- the first keystroke routed
/// through it, or the first screen change after it settled.
///
/// **A clear counts even on a pane flock never created.** That rule used to be
/// provenance-only, which made the feature unreliable for the wrong reason:
/// the set below is in-memory, so restarting flock made every existing pane
/// permanently ineligible, and clearing one did nothing for the rest of the
/// session. A user who clears a pane is asking for a fresh start in it, and
/// that reads the same whoever opened it.
///
/// What keeps this from being intrusive is that a clear is only ever
/// *proposed* here: the pane's screen has to actually come back down to its
/// settled size before the overlay returns, so a Ctrl-L that a full-screen
/// program handled itself, and repainted straight over, changes nothing.
@MainActor
public final class PaneLauncherRegistry {
    /// How long after a pane's first frame its output is still the shell
    /// starting up. Nothing a shell prints on its own way up is use: a prompt
    /// can be one line or five (a starship prompt emits a path line, the
    /// prompt itself, and warnings), and anything the user did in that window
    /// arrived as a keystroke, which hides the overlay by its own route. So
    /// the window is generous on purpose; erring long only delays the hide
    /// until the pane's next output, while erring short is what put the
    /// overlay away before it could be clicked.
    static let settleWindow: TimeInterval = 2

    /// How long after a clear key the pane's screen is watched for the drop
    /// that proves the clear happened. It covers a round trip out to herdr,
    /// through the shell and back, with room to spare; past it the watch stops
    /// rather than leaving the scan running on a pane nobody cleared.
    static let clearWindow: TimeInterval = 2

    /// Timed from the pane's FIRST frame, not from when flock created it: a
    /// pane created in a workspace that is not on screen has no surface, and
    /// so no startup output, until something attaches one.
    private struct Screen {
        let firstReport: Date
        var settledRowCount: Int
    }

    /// Panes the launcher may be offered on at all: created by flock, or
    /// cleared by the user. A pane in neither category never sees it.
    private var offerable: Set<PaneID> = []
    private var hidden: Set<PaneID> = []
    private var screens: [PaneID: Screen] = [:]
    private var clearRequests: [PaneID: Date] = [:]

    public init() {}

    /// Called with the pane id a `pane.split`/`tab.create`/`workspace.create`
    /// response just handed back -- the provenance seam.
    public func registerFlockCreated(_ pane: PaneID) {
        offerable.insert(pane)
    }

    public func recordKeystroke(_ pane: PaneID) {
        hide(pane)
    }

    /// The user asked this pane to clear. Nothing is shown yet, and this makes
    /// no judgement about the pane: it opens the window in which a screen
    /// dropping to its settled size is read as the clear having landed, and
    /// that is what decides.
    ///
    /// Deliberately unguarded by provenance. Clearing is an explicit ask for a
    /// blank pane, and a pane flock did not open is no less blank for it.
    public func recordClearRequested(_ pane: PaneID, at time: Date) {
        clearRequests[pane] = time
    }

    /// Whether this pane's screen is worth reporting on at all. Counting a
    /// surface's non-empty rows is a full buffer scan, so it runs only while
    /// an answer could still change: the pane is still offering the launcher,
    /// or a clear it was just asked for has yet to land.
    public func wantsScreenActivity(_ pane: PaneID, at time: Date) -> Bool {
        isPristine(pane) || hasPendingClear(pane, at: time)
    }

    /// `nonEmptyRowCount` counts the surface's ACTIVE screen, not its
    /// scrollback: a clear empties the screen and keeps the history, so a
    /// count that reached back through the scrollback could never come down
    /// again and the clear below would never be seen.
    ///
    /// It is reported on every real content change. A count that differs from
    /// the one the pane settled at is output, and output the user did not type
    /// is the other way a pane is in use; a repeat of the settled count is a
    /// repaint of the same screen (a blinking cursor, a prompt redrawing its
    /// clock) and means nothing.
    public func recordScreenActivity(_ pane: PaneID, nonEmptyRowCount: Int, at time: Date) {
        guard var screen = screens[pane] else {
            screens[pane] = Screen(firstReport: time, settledRowCount: nonEmptyRowCount)
            return
        }
        if hasPendingClear(pane, at: time) {
            // The screen is back to the size it was when the pane was new, so
            // the clear landed. Anything larger is a program that took Ctrl-L
            // for itself and repainted, and it keeps the overlay away.
            guard nonEmptyRowCount <= screen.settledRowCount else { return }
            clearRequests.removeValue(forKey: pane)
            // A cleared pane becomes offerable whether or not flock opened it:
            // the user asked for a blank pane and got one.
            offerable.insert(pane)
            hidden.remove(pane)
            // The shell redraws its prompt immediately after clearing, and
            // that redraw is startup, not use -- the same reason a fresh pane
            // gets a settle window at all.
            screens[pane] = Screen(firstReport: time, settledRowCount: nonEmptyRowCount)
            return
        }
        guard time.timeIntervalSince(screen.firstReport) >= Self.settleWindow else {
            screen.settledRowCount = nonEmptyRowCount
            screens[pane] = screen
            return
        }
        guard nonEmptyRowCount != screen.settledRowCount else { return }
        hide(pane)
    }

    public func isPristine(_ pane: PaneID) -> Bool {
        offerable.contains(pane) && !hidden.contains(pane)
    }

    private func hasPendingClear(_ pane: PaneID, at time: Date) -> Bool {
        guard let requested = clearRequests[pane] else { return false }
        return time.timeIntervalSince(requested) < Self.clearWindow
    }

    /// The pane's settled row count deliberately survives this: it is what a
    /// later clear is measured against, and it is the one thing that says how
    /// big "empty" is for this particular shell's prompt.
    private func hide(_ pane: PaneID) {
        hidden.insert(pane)
        clearRequests.removeValue(forKey: pane)
    }
}
