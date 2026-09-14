import AppKit
import Carbon.HIToolbox
import Observation
import PaddockCore

/// Owns one divider's own drag gesture, kept apart from `DragController`
/// (see `DividerHandleView`'s own doc comment for why): a divider resolves no
/// drop target, carries no ghost, and never spring-loads, so there is no
/// shared machinery to widen `DragController`'s phase enum for.
///
/// `DividerDragMachine` (`PaddockCore`) owns the pure begin/moved/ended/
/// cancelled/abandoned state, the pointer-to-ratio translation, and the
/// Esc latch (composed from `DragGestureMachine`, the same latch the pane
/// drags use); this class is only the AppKit-facing shell around it -- the
/// Esc monitor, the resign-active observer, and the async call into
/// `commit` on release.
@MainActor
@Observable
final class DividerDragCoordinator {
    private(set) var liveRatio: Double?

    private var machine = DividerDragMachine()
    /// Takes the tab as a parameter rather than a value this closure
    /// captures: the closure itself is frozen for this coordinator's whole
    /// lifetime (constructed once, in `DividerHandleView`'s `@State`), but
    /// `DividerHandleView`'s own view identity is reused across a tab
    /// switch whenever a divider shares the same `path` in both tabs (the
    /// root divider's path is always `[]`) -- so the truth has to come from
    /// `machine.ended()`'s own op, sourced fresh from whichever `divider`
    /// THIS gesture began with, never from a value baked in at construction.
    private let commit: (TabID, [Bool], Double) async -> Void
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    init(commit: @escaping (TabID, [Bool], Double) async -> Void) {
        self.commit = commit
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
        guard case .dragging(_, let start, _) = machine.phase else { return }
        liveRatio = start
        installMonitors()
    }

    /// `pointer` is canvas-local, matching `divider.regionFrame`'s own
    /// space.
    func moved(to pointer: CGPoint) {
        machine.moved(to: pointer)
        guard case .dragging(_, _, let live) = machine.phase else { return }
        liveRatio = live
    }

    /// A committed op holds `liveRatio` (and so the live footprint preview)
    /// until `commit` itself resolves, rather than clearing it up front: the
    /// optimistic overlay `commit` triggers lands synchronously inside that
    /// same call, before its own network await, but clearing the override
    /// FIRST would still fall back to the pre-drag model for however many
    /// main-actor hops stand between here and that point -- a visible snap
    /// back, then a second snap once the prediction lands. A non-committing
    /// end (no op at all) has nothing to wait for, so it clears immediately.
    func ended() {
        removeMonitors()
        let op = machine.ended()
        guard case let .setSplitRatio(tab, path, ratio)? = op else {
            liveRatio = nil
            return
        }
        Task {
            await commit(tab, path, ratio)
            liveRatio = nil
        }
    }

    private func cancel() {
        _ = machine.cancelled()
        liveRatio = nil
    }

    /// The app resigned active with the button still down: no `leftMouseUp`
    /// is ever coming to this window. Same shape as `DragCoordinator.abandon()`
    /// -- ends the gesture outright, issuing no commit.
    private func abandon() {
        removeMonitors()
        machine.abandoned()
        liveRatio = nil
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
