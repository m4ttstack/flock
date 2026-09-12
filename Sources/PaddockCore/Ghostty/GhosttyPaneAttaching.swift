import Foundation

/// One pane's live control-plane surface: a real libghostty surface whose PTY
/// child is the 18f bridge (`ControlBridge`), attached to the pane over its
/// own herdr connection -- nothing like `PaneObserveAttaching`'s frame
/// stream. `PaddockCore` never constructs one (that needs AppKit and
/// `GhosttyKit`, both app-target-only); this is the seam a concrete
/// `GhosttySession` wrapper conforms to from `Sources/Paddock`, and that a
/// fake substitutes for in `SessionViewModelTests`.
@MainActor
public protocol GhosttyPaneSurface: AnyObject {
    /// Called on every attach for a pane that already has a surface (a
    /// layout-cell dims change, most often). A real surface's actual size
    /// comes from its NSView's own pixel layout, never from this call --
    /// see the concrete conformance's doc comment for why the call still
    /// exists on this protocol rather than being dropped.
    func resize(cols: Int, rows: Int)

    /// Tears the surface down: frees the libghostty surface, which ends the
    /// bridge's PTY and, with it, the bridge process and its own herdr
    /// control child.
    func detach()

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
    func makeSurface(for pane: PaneID, cols: Int, rows: Int) -> any GhosttyPaneSurface
}
