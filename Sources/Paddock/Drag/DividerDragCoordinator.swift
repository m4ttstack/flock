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
/// and release monitors, the resign-active observer, the async call into
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
    /// Set when a stale commit's own flush was skipped because a later
    /// drag already owned suppression at the time it resolved -- that
    /// commit's panes are otherwise never sent again (nothing else changes
    /// their `paneBoxDims` once the drag that moved them is over). The
    /// NEXT teardown of whichever drag currently owns suppression honors it
    /// by flushing instead of merely resuming, sweeping up the stale
    /// commit's panes along with its own.
    private var flushOwed = false
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var releaseMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

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
        // Best-effort: this coordinator is session-scoped, so in practice
        // `deinit` only runs at app shutdown, where whether this lands
        // barely matters -- but a stray mid-drag deallocation must not
        // leave suppression stranded either, and `deinit` cannot touch
        // `@MainActor` state directly (it runs outside isolation even for
        // a `@MainActor` class). Captured locally rather than via `self`,
        // which `deinit` may not close over into an escaping task.
        let viewModel = self.viewModel
        Task { @MainActor in
            await viewModel.flushPaneBoxDimsAfterDividerDrag()
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
    /// preview) and the pane-box-dims suppression until `setSplitRatio`
    /// itself resolves, rather than clearing them up front: the optimistic
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
    /// clear `liveOverride`/resume suppression immediately, undoing the
    /// "hold until the commit resolves" behavior above for a commit that is
    /// still in flight.
    func ended() {
        guard machine.phase != .idle else { return }
        removeMonitors()
        let op = machine.ended()
        guard case let .setSplitRatio(tab, path, ratio)? = op else {
            teardown()
            return
        }
        let started = generation
        Task {
            await viewModel.setSplitRatio(tab: tab, path: path, ratio: ratio)
            guard self.generation == started else {
                // A later drag started before this resolved. If it is
                // STILL live, touching suppression or the override here
                // would send ITS still-uncommitted grid, or blow away ITS
                // live preview -- `flushOwed` carries this commit's own
                // obligation to whichever teardown runs next. But if that
                // later drag has ALREADY ended by now (its own `began`
                // bumped `generation`, then it finished before THIS task
                // got here), no future teardown is coming to ever consume
                // the flag -- nothing is currently suppressing, so this
                // commit's panes would otherwise sit stranded until some
                // UNRELATED later drag happened to end. Flush directly
                // instead of setting `flushOwed` in that case.
                if self.machine.phase == .idle {
                    self.flushOwed = false
                    await self.viewModel.flushPaneBoxDimsAfterDividerDrag()
                } else {
                    self.flushOwed = true
                }
                return
            }
            self.liveOverride = nil
            self.flushOwed = false
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
    /// clears the preview, and either lifts suppression with no send of its
    /// own -- the reverted geometry reports a DIFFERENT box than whatever
    /// was last suppressed, which the ordinary `setPaneBoxDims` path picks
    /// up and sends on its own, so an explicit flush here would instead
    /// send the about-to-be-abandoned mid-drag size first -- or, when an
    /// EARLIER drag's own commit left a flush owed, performs that flush
    /// now: this drag is over, so its own subtree's mid-drag values are no
    /// longer being protected either, and the earlier commit's panes have
    /// no other path left to ever reach herdr again.
    private func teardown() {
        liveOverride = nil
        if flushOwed {
            flushOwed = false
            Task { await viewModel.flushPaneBoxDimsAfterDividerDrag() }
        } else {
            viewModel.resumePaneBoxDimsSends()
        }
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
