import Foundation

/// Tracks per-pane provenance and activity for the new-pane harness launcher
/// overlay: pristine only for a pane paddock itself created this session,
/// until that pane is in use -- the first keystroke routed through it, or the
/// first screen change after it settled -- permanently thereafter
/// (`hiddenPermanently` is never pruned). A pane never registered via
/// `registerPaddockCreated` -- i.e. one herdr itself created -- is never
/// pristine.
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

    /// Timed from the pane's FIRST frame, not from when paddock created it: a
    /// pane created in a workspace that is not on screen has no surface, and
    /// so no startup output, until something attaches one.
    private struct Screen {
        let firstReport: Date
        var settledRowCount: Int
    }

    private var createdByPaddock: Set<PaneID> = []
    private var hiddenPermanently: Set<PaneID> = []
    private var screens: [PaneID: Screen] = [:]

    public init() {}

    /// Called with the pane id a `pane.split`/`tab.create`/`workspace.create`
    /// response just handed back -- the provenance seam.
    public func registerPaddockCreated(_ pane: PaneID) {
        createdByPaddock.insert(pane)
    }

    public func recordKeystroke(_ pane: PaneID) {
        hide(pane)
    }

    /// `nonEmptyRowCount` is the surface's own retained-screen count, reported
    /// on every real content change. A count that differs from the one the
    /// pane settled at is output, and output the user did not type is the
    /// other way a pane is in use; a repeat of the settled count is a repaint
    /// of the same screen (a blinking cursor, a prompt redrawing its clock)
    /// and means nothing.
    public func recordScreenActivity(_ pane: PaneID, nonEmptyRowCount: Int, at time: Date) {
        guard var screen = screens[pane] else {
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
        createdByPaddock.contains(pane) && !hiddenPermanently.contains(pane)
    }

    private func hide(_ pane: PaneID) {
        hiddenPermanently.insert(pane)
        screens.removeValue(forKey: pane)
    }
}
