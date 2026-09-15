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
/// carry that news. `DividerDragSession.ended()` is a no-op once idle, so the
/// view's callback and the monitor can both fire for the same release with
/// no double-commit.
///
/// `DividerDragSession` (`PaddockCore`) owns the machine, the live override
/// and the ratio commit; this class is the AppKit-facing shell around it:
/// the Esc and release monitors, the resign-active observer, and the resize
/// cursor.
@MainActor
@Observable
final class DividerDragCoordinator {
    private let session: DividerDragSession
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var releaseMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    /// Guards the resize-cursor push below against a double pop: `ended()`,
    /// `cancel()` and `abandon()` each pop once, and this flag is what keeps a
    /// release that follows a cancel from popping a second time.
    private var hasPushedCursor = false

    init(session: DividerDragSession) {
        self.session = session
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

    /// Read by `PaneCanvas` and `DividerHandleView`; see
    /// `DividerDragSession.liveOverride`.
    var liveOverride: (tabID: TabID, path: [Bool], ratio: Double)? { session.liveOverride }

    var isDragging: Bool { session.isDragging }

    func began(_ divider: DividerHandle) {
        guard session.began(divider) else { return }
        (divider.isVerticalLine ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        hasPushedCursor = true
        installMonitors()
    }

    func moved(to pointer: CGPoint, for divider: DividerHandle) {
        session.moved(to: pointer, for: divider)
    }

    /// The cursor covers the drag itself (press to release), not however long
    /// the async commit afterward takes.
    func ended() {
        guard session.ended() else { return }
        removeMonitors()
        popCursorIfPushed()
    }

    private func cancel() {
        session.cancel()
        popCursorIfPushed()
    }

    private func abandon() {
        removeMonitors()
        session.abandon()
        popCursorIfPushed()
    }

    private func popCursorIfPushed() {
        guard hasPushedCursor else { return }
        hasPushedCursor = false
        NSCursor.pop()
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
