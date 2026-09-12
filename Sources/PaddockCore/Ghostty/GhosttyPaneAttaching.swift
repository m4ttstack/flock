import Foundation

/// One pane's live control-plane surface: a real libghostty surface whose PTY
/// child is a herdr-aware bridge process (`ControlBridge`), attached to the
/// pane over its own herdr connection. `PaddockCore` never constructs one
/// (that needs AppKit and `GhosttyKit`, both app-target-only); this is the
/// seam a concrete `GhosttySession` wrapper conforms to from
/// `Sources/Paddock`, and that a fake substitutes for in
/// `SessionViewModelTests`.
/// `Sendable`: race tests hand an instance out of an unstructured `Task`'s
/// `.value`, which requires the crossing type itself to be `Sendable` even
/// though everything stays on the main actor in practice. Every conformance
/// is `@unchecked Sendable` for that reason, never touched off `@MainActor`.
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

    /// Switches the pane's bridge, live, between herdr's `control` and
    /// `observe` session verbs -- the PTY, the surface, and libghostty's own
    /// scrollback all stay exactly as they are; only which verb is behind
    /// the bridge's pipes changes. `async` so a fake can hold it open in a
    /// test the same way `detach()` can; the real conformance is a
    /// synchronous FIFO write underneath.
    func setMode(_ mode: PaneMode) async
}

/// Creates a `GhosttyPaneSurface` for one pane. Implemented in the app
/// target (`GhosttyHost`), injected into `SessionViewModel` -- absent
/// entirely when ghostty could not be initialized, in which case every
/// pane attach is simply a no-op and no pane ever goes live.
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
    ///
    /// `onScreenActivity` is the launcher-pristine contract's OTHER half:
    /// called with the surface's current non-empty retained-row count
    /// whenever the surface reports new content, so a pane whose program
    /// prints real output (never typed into) also hides the overlay, not
    /// only a pane that received a keystroke. Returns whether the surface
    /// should keep reporting; a `false` (the pane is no longer pristine, by
    /// either path) is the surface's own signal to stop polling for this
    /// pane's whole remaining life.
    func makeSurface(
        for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface
}
