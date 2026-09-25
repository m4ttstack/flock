import AppKit
import FlockCore

/// Watches keys and modifier changes for ⌃Tab ahead of the pane's terminal,
/// and for ⌃ being let go, which opens the selection. An event monitor with
/// no view of its own: an `NSView` beside the tab area, however inert, cost
/// the rail's rename editor its focus.
@MainActor
final class WorkspaceSwitcherMonitor {
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// `blocked` is read on every key: while the palette, a rename editor or
    /// the rt modal is up, an idle switcher passes everything through.
    func install(
        switcher: WorkspaceSwitcher,
        blocked: @escaping () -> Bool,
        begin: @escaping (_ reverse: Bool) -> Void,
        open: @escaping () -> Void
    ) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.window?.isMainWindow == true else { return event }
            return Self.handle(event, switcher: switcher, blocked: blocked, begin: begin, open: open)
        }
        // ⌃ let go in another app never reaches this one.
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
        _ event: NSEvent, switcher: WorkspaceSwitcher, blocked: () -> Bool,
        begin: (Bool) -> Void, open: () -> Void
    ) -> NSEvent? {
        let flags = event.modifierFlags
        if event.type == .flagsChanged {
            if switcher.isActive, !flags.contains(.control) { open() }
            return event
        }
        guard switcher.isActive || !blocked() else { return event }
        let decision = WorkspaceSwitcherKey.decide(
            keyCode: event.keyCode, control: flags.contains(.control), shift: flags.contains(.shift),
            command: flags.contains(.command), option: flags.contains(.option), active: switcher.isActive
        )
        switch decision {
        case .pass: return event
        case .next, .previous:
            if switcher.isActive {
                switcher.step(decision == .next ? 1 : -1)
            } else {
                begin(decision == .previous)
            }
        case .commit: open()
        case .cancel: switcher.cancel()
        case .swallow: break
        }
        return nil
    }
}
