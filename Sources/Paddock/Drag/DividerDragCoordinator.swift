import AppKit
import Carbon.HIToolbox
import Observation
import PaddockCore

/// Owns EVERY divider's drag gesture for the whole session, kept apart from
/// `DragController` (see `DividerHandleView`'s own doc comment for why): a
/// divider resolves no drop target, carries no ghost, and never
/// spring-loads, so there is no shared machinery to widen `DragController`'s
/// phase enum for.
///
/// Session-scoped and environment-injected, exactly like `DragCoordinator`
/// -- constructed once in `PaddockApp.init`, never per-divider `@State`.
/// That choice is a correctness requirement, not a style preference: a
/// per-divider coordinator can be torn down mid-drag (a tab switch with the
/// button still down, a `layout.updated` that removes the divider, the tab
/// closing) while nothing but that SAME view's own `.onChange` ever cleared
/// the live footprint override. A torn-down view firing no further events is
/// normal SwiftUI; a coordinator living inside it taking the session's
/// geometry override down with it is not. Living here instead, the
/// coordinator's own `began`/`moved`/`ended`/`cancelled`/`abandoned` are the
/// only ways the override changes, and every one of them is reachable with
/// no view required to still exist.
///
/// The view may still START a drag; it must never be the only thing that
/// can END one. A `.leftMouseUp` window monitor (mirroring
/// `DragCoordinator.installMonitors`) ends the gesture even if
/// `DividerHandleView`'s own `DragGesture.onEnded` never fires -- herdr's
/// own `layout.updated` removing the dragged split, or the tab closing,
/// tears the view down mid-drag with no SwiftUI callback of its own to
/// carry that news. `ended()` itself guards on `machine.phase != .idle`
/// (see its own doc comment for why the machine's own latch alone is not
/// enough here), so the view's callback and the monitor can both fire for
/// the same release with no double-commit.
///
/// `DividerDragMachine` (`PaddockCore`) owns the pure begin/moved/ended/
/// cancelled/abandoned state, the pointer-to-ratio translation, and the
/// Esc latch (composed from `DragGestureMachine`, the same latch the pane
/// drags use); this class is the AppKit-facing shell around it -- the Esc
/// and release monitors, the resign-active observer, and the async call into
/// `viewModel.setSplitRatio` on release. Pane dims are not its business: the
/// live preview's box changes reach herdr through `setPaneBoxDims` like any
/// other box change, and only the ratio waits for release.
@MainActor
@Observable
final class DividerDragCoordinator {
    /// The live footprint preview's own input to `CanvasGeometry`: the tab,
    /// path and ratio of whichever divider is currently being dragged, or
    /// `nil` at rest. `PaneCanvas` reads this directly (no per-row callback)
    /// and `DividerHandleView` compares its own `divider` against it to
    /// decide whether IT is the one drawing the accent line.
    private(set) var liveOverride: (tabID: TabID, path: [Bool], ratio: Double)?

    private var machine = DividerDragMachine()
    private let viewModel: SessionViewModel
    /// Bumped by every `began` and by `cancel`/`abandon`, so a commit's own
    /// override clear, which resolves after the machine has already gone
    /// back to idle, can tell whether it still belongs to the CURRENT drag
    /// and never clears a newer drag's live preview. The mutation itself
    /// (`setSplitRatio`, and its own undo-journal entry) always runs
    /// regardless: it is the user's real, already-decided action, same as
    /// `DragCoordinator`'s own commit outliving a superseding gesture.
    private var generation = 0
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var releaseMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    /// Guards the resize-cursor push below against a double pop: `ended()`
    /// pops it itself (a committed resize never reaches `teardown()`, so it
    /// cannot live there alone), and `cancel()`/`abandon()` each pop once
    /// before their own `teardown()` call -- this flag is what keeps a
    /// release that follows a cancel from popping a second time.
    private var hasPushedCursor = false

    init(viewModel: SessionViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let releaseMonitor {
            NSEvent.removeMonitor(releaseMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    var isDragging: Bool { machine.isDragging }

    /// `divider` alone is enough: `DividerDragMachine.began` derives the
    /// start ratio from the divider's OWN current boundary, never from
    /// wherever the press happened to land inside the gutter.
    func began(_ divider: DividerHandle) {
        guard machine.began(divider) else { return }
        generation += 1
        guard case .dragging(_, let start, _) = machine.phase else { return }
        liveOverride = (divider.tabID, divider.path, start)
        (divider.isVerticalLine ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        hasPushedCursor = true
        installMonitors()
    }

    /// `pointer` is canvas-local, matching `divider.regionFrame`'s own
    /// space. `divider` is the CALLER's own -- with one coordinator shared
    /// by every `DividerHandleView`, a stray report from a divider that is
    /// NOT the one currently dragging must never have its pointer measured
    /// against the dragging divider's `regionFrame`, which would produce a
    /// wrong ratio for a divider that never asked to move at all.
    func moved(to pointer: CGPoint, for divider: DividerHandle) {
        guard case .dragging(let dragging, _, _) = machine.phase, dragging.tabID == divider.tabID, dragging.path == divider.path else { return }
        machine.moved(to: pointer)
        guard case .dragging(_, _, let live) = machine.phase else { return }
        liveOverride = (divider.tabID, divider.path, live)
    }

    /// A committed op holds `liveOverride` (and so the live footprint
    /// preview) until `setSplitRatio` itself resolves, rather than clearing
    /// it up front: the optimistic
    /// overlay it triggers lands synchronously inside that same call,
    /// before its own network await, but clearing first would still fall
    /// back to the pre-drag layout for however many main-actor hops stand
    /// between here and that point -- a visible snap back, then a second
    /// snap once the prediction lands. A non-committing end (no op at all)
    /// has nothing to wait for, so it tears down immediately.
    ///
    /// Reachable twice for the SAME release (the view's own `onEnded` and
    /// the release monitor both observe it, and both are kept rather than
    /// having the monitor consume the event, so AppKit's own state machines
    /// still close out normally). The `machine.phase != .idle` guard is
    /// what makes the second call a true no-op rather than merely a
    /// harmless-looking one: without it, a redundant call after a REAL
    /// commit's own `ended()` already started would run `teardown()` and
    /// clear `liveOverride` immediately, undoing the
    /// "hold until the commit resolves" behavior above for a commit that is
    /// still in flight.
    func ended() {
        guard machine.phase != .idle else { return }
        removeMonitors()
        // Popped here, unconditionally, rather than inside `teardown()`: a
        // COMMITTED resize (the branch below) never calls `teardown()` at
        // all (see its own doc comment), so that is the one path this pop
        // would otherwise miss. The duration this cursor covers is the drag
        // itself (press to release), not however long the async commit
        // afterward takes.
        popCursorIfPushed()
        let op = machine.ended()
        guard case let .setSplitRatio(tab, path, ratio)? = op else {
            teardown()
            return
        }
        let started = generation
        Task {
            await viewModel.setSplitRatio(tab: tab, path: path, ratio: ratio)
            guard self.generation == started else { return }
            self.liveOverride = nil
        }
    }

    private func cancel() {
        generation += 1
        _ = machine.cancelled()
        popCursorIfPushed()
        teardown()
    }

    /// The app resigned active with the button still down: no `leftMouseUp`
    /// is ever coming to this window. Same shape as `DragCoordinator.abandon()`
    /// -- ends the gesture outright, issuing no commit.
    private func abandon() {
        generation += 1
        removeMonitors()
        machine.abandoned()
        popCursorIfPushed()
        teardown()
    }

    private func popCursorIfPushed() {
        guard hasPushedCursor else { return }
        hasPushedCursor = false
        NSCursor.pop()
    }

    /// Shared by every non-committing exit (a no-op release, Esc, abandon).
    /// Clearing the preview reverts to the pre-drag ratio with no ratio op;
    /// the panes' pre-drag grids flow back through `setPaneBoxDims` as the
    /// reverted layout reports them.
    private func teardown() {
        liveOverride = nil
    }

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                guard Int(event.keyCode) == kVK_Escape else { return event }
                self.cancel()
                return nil
            }
        }
        if releaseMonitor == nil {
            releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.ended()
                return event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.abandon() }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let releaseMonitor {
            NSEvent.removeMonitor(releaseMonitor)
        }
        releaseMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }
}
