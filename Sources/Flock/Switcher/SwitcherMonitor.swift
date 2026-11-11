import AppKit
import FlockCore

/// Watches keys and modifier changes for a switcher's trigger ahead of the
/// pane's terminal, and for the trigger being let go, which opens the
/// selection. An event monitor with no view of its own: an `NSView` beside
/// the tab area, however inert, cost the rail's rename editor its focus.
@MainActor
final class SwitcherMonitor<ID: Hashable & Sendable & RawRepresentable<String>> {
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// `blocked` is read on every key: while `SwitcherBlockers` says so, an
    /// idle switcher passes everything through.
    func install(
        switcher: RecentsSwitcher<ID>,
        trigger: SwitcherTrigger,
        blocked: @escaping () -> Bool,
        begin: @escaping (_ reverse: Bool) -> Bool,
        open: @escaping () -> Void
    ) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard FlockWindow.isContent(event.window) else { return event }
            return Self.handle(event, switcher: switcher, trigger: trigger, blocked: blocked, begin: begin, open: open)
        }
        // A trigger let go in another app never reaches this one.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { switcher.cancel() }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }

    private static func handle(
        _ event: NSEvent, switcher: RecentsSwitcher<ID>, trigger: SwitcherTrigger, blocked: () -> Bool,
        begin: (Bool) -> Bool, open: () -> Void
    ) -> NSEvent? {
        let flags = event.modifierFlags
        if event.type == .flagsChanged {
            if switcher.isActive, !switcher.isLingering, !SwitcherKey.isHeld(
                trigger, control: flags.contains(.control), option: flags.contains(.option), command: flags.contains(.command)
            ) {
                open()
            }
            return event
        }
        if switcher.isLingering {
            switcher.cancel()
            if event.keyCode == SwitcherKey.escape { return nil }
        }
        guard switcher.isActive || !blocked() else { return event }
        let decision = SwitcherKey.decide(
            trigger: trigger, keyCode: event.keyCode, control: flags.contains(.control), shift: flags.contains(.shift),
            command: flags.contains(.command), option: flags.contains(.option), active: switcher.isActive
        )
        return switcher.apply(decision, keepsUnopened: trigger.keepsUnopenedPress, begin: begin, open: open) ? nil : event
    }
}
