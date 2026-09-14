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
/// cancelled state and decides whether a real op comes out; this class is
/// only the AppKit-facing shell around it -- the Esc monitor, and the async
/// call into `commit` on release.
@MainActor
@Observable
final class DividerDragCoordinator {
    private(set) var liveRatio: Double?

    private var machine = DividerDragMachine()
    private let commit: (TabID, [Bool], Double) async -> Void
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?

    init(commit: @escaping (TabID, [Bool], Double) async -> Void) {
        self.commit = commit
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    var isDragging: Bool { machine.isDragging }

    /// `pointer` and `canvas` are canvas-local, matching `divider.frame`'s
    /// own space -- the same space `dividers` (every divider in this tab,
    /// for nested-extent resolution) was built in.
    func began(_ divider: DividerHandle, at pointer: CGPoint, dividers: [DividerHandle], canvas: CGRect) {
        let start = DividerDragMath.ratio(atPointer: pointer, divider: divider, dividers: dividers, canvas: canvas)
        machine.began(divider, startRatio: start)
        liveRatio = start
        installEscMonitor()
    }

    func moved(to pointer: CGPoint, dividers: [DividerHandle], canvas: CGRect) {
        guard case .dragging(let divider, _, _) = machine.phase else { return }
        let ratio = DividerDragMath.ratio(atPointer: pointer, divider: divider, dividers: dividers, canvas: canvas)
        machine.moved(to: ratio)
        liveRatio = ratio
    }

    func ended() {
        removeEscMonitor()
        let op = machine.ended()
        liveRatio = nil
        guard case let .setSplitRatio(tab, path, ratio)? = op else { return }
        Task { await commit(tab, path, ratio) }
    }

    private func cancel() {
        removeEscMonitor()
        _ = machine.cancelled()
        liveRatio = nil
    }

    private func installEscMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard Int(event.keyCode) == kVK_Escape else { return event }
            self.cancel()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
