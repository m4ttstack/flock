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
    private let commit: ([Bool], Double) async -> Void
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    init(commit: @escaping ([Bool], Double) async -> Void) {
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

    func ended() {
        removeMonitors()
        let op = machine.ended()
        liveRatio = nil
        guard case let .setSplitRatio(_, path, ratio)? = op else { return }
        Task { await commit(path, ratio) }
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
