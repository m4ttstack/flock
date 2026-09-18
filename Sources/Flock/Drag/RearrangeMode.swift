import AppKit
import Carbon.HIToolbox
import Observation
import FlockCore
import SwiftUI

/// Feeds `RearrangeModeMachine` from its two live triggers -- the View menu's
/// Rearrange Mode item, which carries Cmd+D, and Esc -- plus the drag
/// lifecycle, and publishes the result for the views that repaint or suppress
/// terminal mouse forwarding from it. `dragBegan`/`dragEnded` exist for
/// whatever starts a rearrange drag to call; this type owns only the mode
/// state, never the drag itself. The Esc precedence rule lives in the pure
/// `RearrangeModeMachine`; this class only translates AppKit events into the
/// machine's vocabulary and reads the result back.
///
/// A modifier key is deliberately NOT a route in. Option was one until
/// 2026-09-17 (held for a momentary mode, double-tapped for a sticky one) and
/// cost more than it gave: Option is a text-navigation modifier in the
/// programs Matt runs in these panes, so ordinary editing dimmed every pane
/// and took the mouse away from the terminal. Command is the only modifier a
/// pane's program never receives, which is what makes a Command key equivalent
/// free to claim.
@MainActor
@Observable
public final class RearrangeMode {
    public private(set) var active = false
    /// What the View-menu checkmark reflects. A real stored (tracked)
    /// property, not a passthrough to `machine` (`@ObservationIgnored`, so a
    /// menu reading only this would otherwise never see a change).
    public private(set) var isToggled = false

    @ObservationIgnored private var machine = RearrangeModeMachine()
    /// Read from `deinit`, which runs outside actor isolation for a
    /// `@MainActor` class -- see `GhosttySurfaceView`'s own `windowObservers`
    /// for the same pattern. `@ObservationIgnored` is what makes
    /// `nonisolated(unsafe)` legal here: the Observation macro forbids
    /// `nonisolated` on a mutable property it tracks. It never swallows an
    /// event (always returns it unchanged), it only observes -- Esc is a
    /// terminal key as well as this mode's way out, and the pane has to keep
    /// receiving it.
    @ObservationIgnored nonisolated(unsafe) private var eventMonitor: Any?
    @ObservationIgnored private weak var monitoredWindow: NSWindow?

    public init() {}

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    /// Installs the Esc monitor for `window`; a repeat call for the SAME
    /// window is a no-op, and any earlier monitor is torn down first. A LOCAL
    /// monitor already never fires while another app is frontmost; the
    /// `event.window === window` check inside narrows it further to the one
    /// window this instance is scoped to.
    public func attach(to window: NSWindow) {
        guard monitoredWindow !== window else { return }
        detach()
        monitoredWindow = window
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window, Int(event.keyCode) == kVK_Escape else { return event }
            self.apply(.escPressed)
            return event
        }
    }

    public func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        monitoredWindow = nil
    }

    public func toggle() {
        apply(isToggled ? .toggleOff : .toggleOn)
    }

    public func dragBegan() { apply(.dragBegan) }
    public func dragEnded() { apply(.dragEnded) }

    private func apply(_ event: RearrangeModeMachine.Event) {
        machine.handle(event)
        active = machine.active
        isToggled = machine.isToggled
    }
}

/// Installs `RearrangeMode`'s Esc monitor once this hosting view has a window,
/// which a freshly made view does not have yet; hence the deferred attach
/// below. Teardown is `RearrangeMode.deinit`, not this representable's
/// dismantle: the app has exactly one window for its whole life, so the
/// monitor's lifetime is the app's.
struct RearrangeKeyMonitorHost: NSViewRepresentable {
    let rearrangeMode: RearrangeMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { attach(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(nsView)
    }

    private func attach(_ view: NSView) {
        guard let window = view.window else { return }
        rearrangeMode.attach(to: window)
    }
}
