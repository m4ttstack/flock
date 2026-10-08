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

/// Whether a pane's program has ever claimed the mouse, SwiftUI-observed like
/// `FirstFrameLatch`. Flips once: a program that hands its pane on (an
/// `rt run` picker to the script it picked) turns the mouse off again, and
/// what was claimed stays claimed.
@MainActor
@Observable
public final class MouseClaimLatch {
    public private(set) var claimed = false

    public init() {}

    public func markClaimed() {
        guard !claimed else { return }
        claimed = true
    }
}

/// Whether a pane's program has the mouse right now, SwiftUI-observed like
/// `FirstFrameLatch`. Unlike `MouseClaimLatch` it follows the program both
/// ways.
@MainActor
@Observable
public final class MouseCaptureState {
    public private(set) var enabled = false

    public init() {}

    public func set(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
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

    /// One terminal row in points, or nil before libghostty has reported its
    /// cell size. The launcher overlay keeps this many rows clear per row the
    /// screen holds.
    var cellHeight: CGFloat? { get }

    /// Whether the pane's program has ever asked for mouse reporting, as the
    /// bridge reports it. Every rt-ui program does as it takes the screen,
    /// which is how the rt modal knows its program has drawn.
    var hasClaimedMouse: Bool { get }

    /// Whether the pane's program has the mouse now, so a plain right-click in
    /// the focused pane is the program's (see `RightClickDisposition`).
    var programHasMouse: Bool { get }
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
    /// that triggered it -- the launcher contract's ghostty half of
    /// `recordLauncherKeystroke`. Originating the closure here, at the
    /// factory call site, keeps that contract testable against a fake
    /// without any real NSView or NSEvent: a test can invoke it directly and
    /// assert the launcher flag clears.
    ///
    /// `onScreenActivity` is the launcher's screen half: called whenever the
    /// surface's active screen changes, for the whole life of the surface.
    /// `onClearRequested`
    /// fires on the key that asks the pane to clear its screen, after
    /// `onUserInput` for the same event.
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (ScreenActivity) -> Void
    ) async -> any GhosttyPaneSurface
}

/// One read of a surface's active screen: its non-empty row count, a
/// fingerprint of its text, and its last non-empty row (the cursor's line at
/// a prompt), so a screen that changed without changing its count (a line
/// typed, then erased) can be told from one that did not.
public struct ScreenActivity: Equatable, Sendable, ExpressibleByIntegerLiteral {
    public let rows: Int
    public let fingerprint: Int?
    public let lastRow: String?

    public init(rows: Int, fingerprint: Int?, lastRow: String?) {
        self.rows = rows
        self.fingerprint = fingerprint
        self.lastRow = lastRow
    }

    public init(integerLiteral rows: Int) {
        self.init(rows: rows, fingerprint: nil, lastRow: nil)
    }
}
