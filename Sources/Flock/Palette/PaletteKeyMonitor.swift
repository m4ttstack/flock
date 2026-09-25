import AppKit
import FlockCore
import SwiftUI

/// Takes ↑ ↓ ⌃P ⌃N Return and Esc while the palette is up, before the search
/// field or a pane sees them.
struct PaletteKeyMonitor: NSViewRepresentable {
    let onDecision: (PaletteKey.Decision) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onDecision = onDecision
    }

    final class MonitorView: NSView {
        var onDecision: (PaletteKey.Decision) -> Void = { _ in }
        nonisolated(unsafe) private var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                let flags = event.modifierFlags
                let decision = PaletteKey.decide(
                    keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                    control: flags.contains(.control), command: flags.contains(.command)
                )
                guard decision != .pass else { return event }
                self.onDecision(decision)
                return nil
            }
        }
    }
}
