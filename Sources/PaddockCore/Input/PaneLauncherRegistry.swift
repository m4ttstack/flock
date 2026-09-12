import Foundation

/// Tracks per-pane provenance and activity for the new-pane harness launcher
/// overlay: pristine only for a pane paddock itself created this session,
/// until the first keystroke routed through it OR the first screen output
/// beyond the bare prompt row(s) -- whichever comes first, permanently
/// thereafter (`hiddenPermanently` is never pruned). A pane never registered
/// via `registerPaddockCreated` -- i.e. one herdr itself created -- is never
/// pristine.
@MainActor
public final class PaneLauncherRegistry {
    private var createdByPaddock: Set<PaneID> = []
    private var hiddenPermanently: Set<PaneID> = []

    public init() {}

    /// Called with the pane id a `pane.split`/`tab.create`/`workspace.create`
    /// response just handed back -- the provenance seam.
    public func registerPaddockCreated(_ pane: PaneID) {
        createdByPaddock.insert(pane)
    }

    public func recordKeystroke(_ pane: PaneID) {
        hiddenPermanently.insert(pane)
    }

    /// `nonEmptyRowCount` is the surface's own retained-screen heuristic: a
    /// bare prompt is at most 2 non-empty rows (the shell's own startup
    /// line, if any, and the prompt line itself); anything beyond that
    /// means real output has appeared.
    public func recordScreenActivity(_ pane: PaneID, nonEmptyRowCount: Int) {
        guard nonEmptyRowCount > 2 else { return }
        hiddenPermanently.insert(pane)
    }

    public func isPristine(_ pane: PaneID) -> Bool {
        createdByPaddock.contains(pane) && !hiddenPermanently.contains(pane)
    }
}
