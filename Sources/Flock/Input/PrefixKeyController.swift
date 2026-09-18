import AppKit
import FlockCore
import Observation
import SwiftUI

extension HerdrKeyPress {
    /// `nil` for an event that names no key at all, which is left for the
    /// responder chain rather than guessed at.
    init?(_ event: NSEvent) {
        var modifiers = HerdrKeyModifiers()
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        guard let press = HerdrKeyTranslation.press(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) else { return nil }
        self = press
    }
}

/// herdr's prefix key inside flock: reads the user's own herdr config, takes
/// the keys it binds before the pane sees them, and hands everything else
/// through untouched.
///
/// A window-scoped LOCAL event monitor rather than a hook inside the pane
/// view, for the same reason `RearrangeMode` uses one: it sees a key press
/// before the responder chain does, which is what lets a bound key be taken
/// rather than typed. Unlike that one, this monitor does swallow events --
/// returning `nil` is how a prefix press stops being input for the program.
@MainActor
@Observable
public final class PrefixKeyController {
    /// True between the prefix press and the key that follows it, for
    /// anything on screen that wants to say so.
    public private(set) var isAwaitingKey = false

    @ObservationIgnored private var machine: PrefixKeyMachine
    @ObservationIgnored private let source: HerdrKeybindingsSource
    @ObservationIgnored private let isTyping: @MainActor () -> Bool
    @ObservationIgnored private let context: @MainActor () -> PrefixActionContext
    @ObservationIgnored private let run: @MainActor (PrefixIntent) -> Void
    /// Read from `deinit`, which runs outside actor isolation for a
    /// `@MainActor` class; the same shape `RearrangeMode` uses for its own.
    @ObservationIgnored nonisolated(unsafe) private var eventMonitor: Any?
    @ObservationIgnored private weak var monitoredWindow: NSWindow?

    public init(
        source: HerdrKeybindingsSource,
        isTyping: @escaping @MainActor () -> Bool,
        context: @escaping @MainActor () -> PrefixActionContext,
        run: @escaping @MainActor (PrefixIntent) -> Void
    ) {
        self.source = source
        self.isTyping = isTyping
        self.context = context
        self.run = run
        machine = PrefixKeyMachine(keybindings: source.current())
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    public func attach(to window: NSWindow) {
        guard monitoredWindow !== window else { return }
        detach()
        monitoredWindow = window
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            return self.handle(event)
        }
    }

    public func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        monitoredWindow = nil
    }

    /// The event to go on dispatching, or `nil` when this took the key.
    public func handle(_ event: NSEvent) -> NSEvent? {
        // A rename editor is a text field, and every key in one is text: the
        // prefix would otherwise take Ctrl+A away from the start of the line.
        guard !isTyping(), let press = HerdrKeyPress(event) else { return event }
        machine.update(keybindings: source.current())
        let outcome = machine.handle(press)
        isAwaitingKey = machine.mode == .prefix
        switch outcome {
        case .sendToPane:
            return event
        case .swallow, .enteredPrefix:
            return nil
        case .run(let binding):
            run(PrefixIntents.intent(for: binding, in: context()))
            return nil
        }
    }
}

/// Installs the monitor once the hosting view has a window, which a freshly
/// made view does not have yet. Teardown is the controller's own `deinit`:
/// the app has one window for its whole life, so the monitor's lifetime is
/// the app's.
struct PrefixKeyMonitorHost: NSViewRepresentable {
    let controller: PrefixKeyController

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
        controller.attach(to: window)
    }
}
