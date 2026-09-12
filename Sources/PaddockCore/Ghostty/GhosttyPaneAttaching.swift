import Foundation

/// One pane's live control-plane surface: a real libghostty surface whose PTY
/// child is a herdr-aware bridge process, attached to the pane over its own
/// herdr connection -- nothing like `PaneObserveAttaching`'s frame stream.
/// `PaddockCore` never constructs one (that needs AppKit and `GhosttyKit`,
/// both app-target-only); this is the seam a concrete `GhosttySession`
/// wrapper conforms to from `Sources/Paddock`, and that a fake substitutes
/// for in `SessionViewModelTests`.
/// `Sendable`: race tests hand an instance out of an unstructured `Task`'s
/// `.value` (the same way the observe path's `PaneLiveFeed` already does),
/// which requires the crossing type itself to be `Sendable` even though
/// everything stays on the main actor in practice. Every conformance is
/// `@unchecked Sendable` for that reason, never touched off `@MainActor`.
@MainActor
public protocol GhosttyPaneSurface: AnyObject, Sendable {
    /// Called on every attach for a pane that already has a surface (a
    /// layout-cell dims change, most often). A real surface's actual size
    /// comes from its NSView's own pixel layout, never from this call --
    /// see the concrete conformance's doc comment for why the call still
    /// exists on this protocol rather than being dropped.
    func resize(cols: Int, rows: Int)

    /// Tears the surface down: frees the libghostty surface, which ends the
    /// bridge's PTY and, with it, the bridge process and its own herdr
    /// control child. `async` so a real teardown that needs to wait on
    /// something can, without changing this contract later.
    func detach() async

    /// Types `text` into the surface as if the user had, writing straight to
    /// the bridge's PTY -- the launcher overlay's route for a ghostty pane
    /// (`pane.send_input`/`InputRouter` never apply here; there is no herdr
    /// attach in between to send them over).
    func typeText(_ text: String)
}

/// Creates a `GhosttyPaneSurface` for one pane. Implemented in the app
/// target (`GhosttyHost`), injected into `SessionViewModel` the same way
/// `PaneObserveAttaching` is -- absent entirely when ghostty could not be
/// initialized, in which case ghostty attach is simply a no-op and every
/// pane stays on the observe path.
@MainActor
public protocol GhosttyPaneFactory {
    /// `onUserInput` is handed to the surface so it can report real user
    /// input (a keystroke, not a bare modifier change) back up to
    /// `SessionViewModel` without `PaddockCore` ever seeing the AppKit event
    /// that triggered it -- the launcher-pristine contract's ghostty half of
    /// `recordLauncherKeystroke`. Originating the closure here, at the
    /// factory call site, keeps that contract testable against a fake
    /// without any real NSView or NSEvent: a test can invoke it directly and
    /// assert the pristine flag clears.
    func makeSurface(for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void) async -> any GhosttyPaneSurface
}
