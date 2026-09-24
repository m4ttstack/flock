import AppKit
import FlockCore
import SwiftUI

/// Takes ⌘W, and any plain key while a strip is up, before the terminal or the
/// window's own Close sees it. Installed while the modal is on screen: the view
/// leaving its window removes the monitor.
struct RtModalKeyMonitor: NSViewRepresentable {
    let stripShown: Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.stripShown = stripShown
        view.onClose = onClose
    }

    final class MonitorView: NSView {
        var stripShown = false
        var onClose: () -> Void = {}
        nonisolated(unsafe) private var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Behind the box's content, so it must never be what a click lands on.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                let flags = event.modifierFlags
                let decision = RtModalKey.decide(
                    characters: event.charactersIgnoringModifiers,
                    command: flags.contains(.command), shift: flags.contains(.shift),
                    option: flags.contains(.option), control: flags.contains(.control),
                    stripShown: self.stripShown
                )
                guard decision == .close else { return event }
                self.onClose()
                return nil
            }
        }
    }
}
