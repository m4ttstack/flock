import AppKit
import Observation
import PaddockCore
import SwiftUI

/// Feeds `RearrangeModeMachine` from the two live triggers -- a held Control
/// key and the View-menu sticky toggle -- plus the drag lifecycle, and
/// publishes the result for the views that repaint or suppress terminal
/// mouse forwarding from it. `dragBegan`/`dragEnded` exist for whatever
/// starts a rearrange drag to call; this type owns only the mode state, never
/// the drag itself.
@MainActor
@Observable
public final class RearrangeMode {
    public enum Source: Equatable, Sendable {
        case held
        case toggled
    }

    public private(set) var active = false
    public private(set) var source: Source = .held
    /// The sticky half only -- what the View-menu checkmark reflects. A held
    /// Control with the toggle off reads `false` here even while `active`.
    /// A real stored (tracked) property, not a passthrough to `machine`
    /// (`@ObservationIgnored`, so a menu reading only this would otherwise
    /// never see a change).
    public private(set) var isToggled = false

    @ObservationIgnored private var machine = RearrangeModeMachine()
    /// Read from `deinit`, which runs outside actor isolation for a
    /// `@MainActor` class -- see `GhosttySurfaceView`'s own
    /// `windowObservers` for the same pattern. `@ObservationIgnored` is what
    /// makes `nonisolated(unsafe)` legal here: the Observation macro forbids
    /// `nonisolated` on a mutable property it tracks.
    @ObservationIgnored nonisolated(unsafe) private var controlMonitor: Any?
    @ObservationIgnored private weak var monitoredWindow: NSWindow?

    public init() {}

    deinit {
        if let controlMonitor {
            NSEvent.removeMonitor(controlMonitor)
        }
    }

    /// Installs the Control-key monitor for `window`; a repeat call for the
    /// SAME window is a no-op, and any earlier monitor is torn down first.
    /// A LOCAL monitor already never fires while another app is frontmost;
    /// the `event.window === window` check inside narrows it further to the
    /// one window this instance is scoped to.
    public func attach(to window: NSWindow) {
        guard monitoredWindow !== window else { return }
        detach()
        monitoredWindow = window
        controlMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.window === window else { return event }
            self.setControlHeld(event.modifierFlags.contains(.control))
            return event
        }
    }

    public func detach() {
        if let controlMonitor {
            NSEvent.removeMonitor(controlMonitor)
        }
        controlMonitor = nil
        monitoredWindow = nil
    }

    public func toggle() {
        apply(isToggled ? .toggleOff : .toggleOn)
    }

    public func dragBegan() { apply(.dragBegan) }
    public func dragEnded() { apply(.dragEnded) }

    private func setControlHeld(_ held: Bool) {
        apply(held ? .controlDown : .controlUp)
    }

    private func apply(_ event: RearrangeModeMachine.Event) {
        machine.handle(event)
        active = machine.active
        isToggled = machine.isToggled
        source = machine.isToggled ? .toggled : .held
    }
}

/// Installs `RearrangeMode`'s Control monitor once this hosting view has a
/// window, mirroring `MainWindow.TitlebarConfigurator`'s own
/// window-not-yet-available dance. Teardown is `RearrangeMode.deinit`, not
/// this representable's dismantle: the app has exactly one window for its
/// whole life, so the monitor's lifetime is the app's.
struct RearrangeControlMonitorHost: NSViewRepresentable {
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
