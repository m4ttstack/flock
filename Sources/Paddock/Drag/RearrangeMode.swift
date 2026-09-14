import AppKit
import Carbon.HIToolbox
import Observation
import PaddockCore
import SwiftUI

/// Feeds `RearrangeModeMachine` from its three live triggers -- a held Option
/// key, a double-tap of that same key, and the View-menu sticky toggle --
/// plus the drag lifecycle and Esc, and publishes the result for the views
/// that repaint or suppress terminal mouse forwarding from it.
/// `dragBegan`/`dragEnded` exist for whatever starts a rearrange drag to
/// call; this type owns only the mode state, never the drag itself. All tap
/// timing, hold-versus-tap classification, and Esc precedence live in the
/// pure `RearrangeModeMachine` -- this class only translates AppKit events
/// into the machine's vocabulary and reads the result back.
///
/// Option, not Control: on macOS a Control-click IS a secondary click (AppKit
/// delivers `rightMouseDown`, never `mouseDown`, for it -- see this repo's
/// own `NSEvent.isSecondaryButtonEvent`, which already encodes that fact for
/// the legend tap guard), so a Control-held press on a pane body could never
/// have started a rearrange drag at all. Option carries no such remap
/// (confirmed against Apple's own "secondary click" documentation, which
/// names only Control), and Option+right-click is already paddock's
/// herdr-menu gesture, so Option reads as "paddock's own layer," consistent
/// with this mode's own meaning.
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
    /// Option with the toggle off reads `false` here even while `active`.
    /// A real stored (tracked) property, not a passthrough to `machine`
    /// (`@ObservationIgnored`, so a menu reading only this would otherwise
    /// never see a change).
    public private(set) var isToggled = false

    @ObservationIgnored private var machine = RearrangeModeMachine()
    /// Read from `deinit`, which runs outside actor isolation for a
    /// `@MainActor` class -- see `GhosttySurfaceView`'s own
    /// `windowObservers` for the same pattern. `@ObservationIgnored` is what
    /// makes `nonisolated(unsafe)` legal here: the Observation macro forbids
    /// `nonisolated` on a mutable property it tracks. Watches Option itself
    /// (`.flagsChanged`), Esc, and every other key/mouse-button event so the
    /// machine's double-tap sequence can be cancelled by "anything else"
    /// happening in between, per the ruling -- it never swallows an event
    /// (always returns it unchanged), it only observes.
    @ObservationIgnored nonisolated(unsafe) private var eventMonitor: Any?
    /// Become/resign-key and become/resign-active observers -- see `attach`.
    /// A `flagsChanged` edge is only ever delivered to a window that is key,
    /// so an edge-triggered monitor alone strands `optionHeld` whenever
    /// Option changes state off-window (another app, or this window not yet
    /// key): these observers re-sync from `NSEvent.modifierFlags` (the
    /// ambient state, not an edge) at every point that gap can occur. Resign
    /// forces the held trigger off outright, through a dedicated machine
    /// event rather than a plain `.modifierUp` -- a resign is not a real key
    /// release, and running it through the tap-timing path could misread an
    /// interrupted hold as a suspiciously short, clean tap.
    @ObservationIgnored nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var monitoredWindow: NSWindow?

    public init() {}

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        let center = NotificationCenter.default
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
    }

    /// Installs the event monitor for `window`, plus the window/app
    /// activation observers that keep it honest across a resign; a repeat
    /// call for the SAME window is a no-op, and any earlier monitor/observers
    /// are torn down first. A LOCAL monitor already never fires while another
    /// app is frontmost; the `event.window === window` check inside narrows
    /// it further to the one window this instance is scoped to.
    public func attach(to window: NSWindow) {
        guard monitoredWindow !== window else { return }
        detach()
        monitoredWindow = window
        let watched: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: watched) { [weak self] event in
            guard let self, event.window === window else { return event }
            switch event.type {
            case .flagsChanged:
                self.setOptionHeld(event.modifierFlags.contains(.option))
            case .keyDown:
                if Int(event.keyCode) == kVK_Escape {
                    self.apply(.escPressed)
                } else {
                    self.apply(.otherInputOccurred)
                }
            default:
                self.apply(.otherInputOccurred)
            }
            return event
        }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.syncAmbientOptionHeld()
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.apply(.modifierForcedUp)
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.syncAmbientOptionHeld()
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.apply(.modifierForcedUp)
            },
        ]
        // The host view can mount after `window` is already key (the common
        // case at launch: `RearrangeOptionMonitorHost` attaches async), so
        // a became-key notification for THIS activation may already have
        // fired before the observer above existed -- sync once, here, for
        // that case.
        if window.isKeyWindow {
            syncAmbientOptionHeld()
        }
    }

    public func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        let center = NotificationCenter.default
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
        lifecycleObservers = []
        monitoredWindow = nil
    }

    public func toggle() {
        apply(isToggled ? .toggleOff : .toggleOn)
    }

    public func dragBegan() { apply(.dragBegan) }
    public func dragEnded() { apply(.dragEnded) }

    private func setOptionHeld(_ held: Bool) {
        apply(held ? .modifierDown : .modifierUp)
    }

    private func syncAmbientOptionHeld() {
        setOptionHeld(NSEvent.modifierFlags.contains(.option))
    }

    private func apply(_ event: RearrangeModeMachine.Event) {
        machine.handle(event)
        active = machine.active
        isToggled = machine.isToggled
        source = machine.isToggled ? .toggled : .held
    }
}

/// Installs `RearrangeMode`'s event monitor once this hosting view has a
/// window, mirroring `MainWindow.TitlebarConfigurator`'s own
/// window-not-yet-available dance. Teardown is `RearrangeMode.deinit`, not
/// this representable's dismantle: the app has exactly one window for its
/// whole life, so the monitor's lifetime is the app's.
struct RearrangeOptionMonitorHost: NSViewRepresentable {
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
