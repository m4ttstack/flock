import Foundation
import Observation

/// Tracks whether a pane's surface has painted its first full frame -- the
/// SwiftUI-observed latch a cold `PaneCellView` crossfades on. A separate,
/// minimal `@Observable` type rather than making the whole, AppKit-only
/// `GhosttySession` observable, so this is the only piece of surface state
/// SwiftUI ever tracks. Flips once, monotonically: a warm (parked and
/// reattached) surface already carries `true` from its earlier life, so a
/// re-host never shows the card again.
@MainActor
@Observable
public final class FirstFrameLatch {
    public private(set) var received = false

    public init() {}

    public func markReceived() {
        guard !received else { return }
        received = true
    }

    /// The pane's bridge gave up retaking its herdr hold, so what the surface
    /// is showing is a frame that is no longer live. The one thing that clears
    /// this latch, and the reason it is monotonic only WITHIN a hold: the
    /// status card is the app's existing way of saying a pane has no content
    /// yet, and a pane with no herdr client at all is in exactly that state.
    /// The bridge re-arms its own first-frame gate at the same moment, so a
    /// later take's full frame sets this again and the card crossfades away.
    public func markHoldLost() {
        guard received else { return }
        received = false
    }
}

/// One pane's live control-plane surface: a real libghostty surface whose PTY
/// child is a herdr-aware bridge process (`ControlBridge`), attached to the
/// pane over its own herdr connection. `FlockCore` never constructs one
/// (that needs AppKit and `GhosttyKit`, both app-target-only); this is the
/// seam a concrete `GhosttySession` wrapper conforms to from
/// `Sources/Flock`, and that a fake substitutes for in
/// `SessionViewModelTests`.
/// `Sendable`: race tests hand an instance out of an unstructured `Task`'s
/// `.value`, which requires the crossing type itself to be `Sendable` even
/// though everything stays on the main actor in practice. Every conformance
/// is `@unchecked Sendable` for that reason, never touched off `@MainActor`.
@MainActor
public protocol GhosttyPaneSurface: AnyObject, Sendable {
    /// Tears the surface down: frees the libghostty surface, which ends the
    /// bridge's PTY and, with it, the bridge process and its own herdr
    /// control child. `async` so a real teardown that needs to wait on
    /// something can, without changing this contract later.
    func detach() async

    /// Parks the surface: kept alive, with its bridge still attached, rather
    /// than torn down, so a later `unpark()` shows the pane's CURRENT
    /// content instead of a freshly recreated surface. The real conformance
    /// marks the surface occluded so libghostty's renderer stops drawing a
    /// pane nothing can see; the PTY keeps writing frames regardless, so the
    /// surface is current whenever it is looked at again.
    func park()

    /// Reverses `park()`. Idempotent: calling it on a surface that was never
    /// parked is a harmless no-op.
    func unpark()

    /// Drops flock's herdr control client for this pane, which drops the
    /// pane's `direct_attach_resize_lock` with it, so herdr sizes the pane for
    /// its own shell clients again. The surface, its PTY, its scrollback, the
    /// pane's program and this pane's place in the warm cache all survive:
    /// only the herdr client goes. Until `takeHerdrHold()`, the pane's frames
    /// stop arriving, so what the surface shows is the last frame it was sent.
    func releaseHerdrHold()

    /// Reverses `releaseHerdrHold()`: a new control client at the PTY's
    /// current size, which retakes the lock and is answered with a full frame.
    /// Idempotent, like `unpark()`.
    func takeHerdrHold()

    /// Turns the launcher's row counting back on after the surface switched
    /// it off, for a launcher offered again at a prompt nobody has measured.
    func resumeScreenActivityReporting()

    /// Whether the bridge has reported this surface's first full-frame paint,
    /// ever, over the status FIFO's `flock.first_frame` line. `PaneCellView`
    /// reads this to decide whether a cold attach still shows the status card;
    /// a warm (parked-then-reattached) surface already carries `true` from its
    /// earlier life, so seeding `ghosttySurface` from the pool at a cell's
    /// `init` never re-shows the card for it.
    ///
    /// What this latches is "the bridge wrote a full-redraw
    /// `terminal.frame`'s bytes to the PTY", not "libghostty has drawn them
    /// on screen" -- those are two different ticks (the surface's own render
    /// pass reads the PTY on its own schedule, a frame or two later). The
    /// 150ms crossfade (`PaneCellView.content`'s `.animation`) is what makes
    /// that gap invisible: card and surface are both on screen, opacity
    /// swapping, so the surface has already had time to draw by the time the
    /// card has fully faded.
    var hasFirstFrame: Bool { get }
}

/// Creates a `GhosttyPaneSurface` for one pane. Implemented in the app
/// target (`GhosttyHost`), injected into `SessionViewModel` -- absent
/// entirely when ghostty could not be initialized, in which case every
/// pane attach is simply a no-op and no pane ever goes live.
@MainActor
public protocol GhosttyPaneFactory {
    /// `onUserInput` is handed to the surface so it can report real user
    /// input (a keystroke, not a bare modifier change) back up to
    /// `SessionViewModel` without `FlockCore` ever seeing the AppKit event
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
    /// should keep reporting; a `false` is the surface's own signal to stop
    /// counting rows, which is a full buffer scan and not something to leave
    /// running on a pane whose answer can no longer change.
    ///
    /// `onClearRequested` fires on the key that asks a pane to clear its
    /// screen. It shows nothing on its own -- it turns the row count back on
    /// for long enough to see whether the screen actually came back down to
    /// the size it started at, which is what separates a shell that cleared
    /// from a full-screen program that took the key and repainted.
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface
}
