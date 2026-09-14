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
/// closing) while nothing but that SAME view's own `.onChange` ever resumed
/// pane box dims sends or cleared the live footprint override. A torn-down
/// view firing no further events is normal SwiftUI; a coordinator living
/// inside it taking the session's send-suppression and geometry override
/// down with it is not. Living here instead, the coordinator's own
/// `began`/`moved`/`ended`/`cancelled`/`abandoned` are the only ways
/// suppression or the override change, and every one of them is reachable
/// with no view required to still exist.
///
/// `DividerDragMachine` (`PaddockCore`) owns the pure begin/moved/ended/
/// cancelled/abandoned state, the pointer-to-ratio translation, and the
/// Esc latch (composed from `DragGestureMachine`, the same latch the pane
/// drags use); this class is the AppKit-facing shell around it -- the Esc
/// monitor, the resign-active observer, the async call into
/// `viewModel.setSplitRatio` on release, and the pane-box-dims suppression
/// that ride alongside it.
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
    /// pane-box-dims flush and override clear -- both async, resolving after
    /// the machine has already gone back to idle -- can tell whether they
    /// still belong to the CURRENT drag before touching shared state. The
    /// mutation itself (`setSplitRatio`, and its own undo-journal entry)
    /// always runs regardless: it is the user's real, already-decided
    /// action, same as `DragCoordinator`'s own commit outliving a
    /// superseding gesture.
    private var generation = 0
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    init(viewModel: SessionViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
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
        viewModel.beginSuppressingPaneBoxDimsSends()
        installMonitors()
    }

    /// `pointer` is canvas-local, matching `divider.regionFrame`'s own
    /// space.
    func moved(to pointer: CGPoint) {
        machine.moved(to: pointer)
        guard case .dragging(let divider, _, let live) = machine.phase else { return }
        liveOverride = (divider.tabID, divider.path, live)
    }

    /// A committed op holds `liveOverride` (and so the live footprint
    /// preview) and the pane-box-dims suppression until `setSplitRatio`
    /// itself resolves, rather than clearing them up front: the optimistic
    /// overlay it triggers lands synchronously inside that same call,
    /// before its own network await, but clearing first would still fall
    /// back to the pre-drag layout for however many main-actor hops stand
    /// between here and that point -- a visible snap back, then a second
    /// snap once the prediction lands. A non-committing end (no op at all)
    /// has nothing to wait for, so it tears down immediately.
    func ended() {
        removeMonitors()
        let op = machine.ended()
        guard case let .setSplitRatio(tab, path, ratio)? = op else {
            teardown()
            return
        }
        let started = generation
        Task {
            await viewModel.setSplitRatio(tab: tab, path: path, ratio: ratio)
            // A later drag may already own the session's suppression and
            // override by the time this resolves -- flushing or clearing
            // here would send THAT drag's still-uncommitted grid, or blow
            // away its live preview, rather than this one's.
            guard self.generation == started else { return }
            self.liveOverride = nil
            await self.viewModel.flushPaneBoxDimsAfterDividerDrag()
        }
    }

    private func cancel() {
        generation += 1
        _ = machine.cancelled()
        teardown()
    }

    /// The app resigned active with the button still down: no `leftMouseUp`
    /// is ever coming to this window. Same shape as `DragCoordinator.abandon()`
    /// -- ends the gesture outright, issuing no commit.
    private func abandon() {
        generation += 1
        removeMonitors()
        machine.abandoned()
        teardown()
    }

    /// Shared by every non-committing exit (a no-op release, Esc, abandon):
    /// clears the preview and lifts suppression with no flush of its own --
    /// the reverted geometry reports a DIFFERENT box than whatever was last
    /// suppressed, which the ordinary `setPaneBoxDims` path picks up and
    /// sends on its own. An explicit flush here would instead send the
    /// about-to-be-abandoned mid-drag size first, the exact out-and-back
    /// reflow suppression exists to prevent.
    private func teardown() {
        liveOverride = nil
        viewModel.resumePaneBoxDimsSends()
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
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }
}
