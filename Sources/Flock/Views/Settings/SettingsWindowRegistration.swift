import AppKit
import SwiftUI

/// Registers the Settings window with `FlockWindow` and sets its size once,
/// when it is first shown. A window otherwise keeps whatever frame it last
/// had, an earlier resizable build's included.
struct SettingsWindowRegistration: NSViewRepresentable {
    let contentSize: CGSize

    func makeNSView(context: Context) -> RegisteringView { RegisteringView(contentSize: contentSize) }
    func updateNSView(_ view: RegisteringView, context: Context) {}

    final class RegisteringView: NSView {
        private let contentSize: CGSize
        private weak var sized: NSWindow?

        init(contentSize: CGSize) {
            self.contentSize = contentSize
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== sized else { return }
            sized = window
            FlockWindow.settings = window
            // After SwiftUI's own first sizing pass, which would undo it.
            DispatchQueue.main.async { [contentSize] in
                window.styleMask.remove(.resizable)
                let content = window.contentRect(forFrameRect: window.frame)
                guard abs(content.width - contentSize.width) > 0.5 || abs(content.height - contentSize.height) > 0.5 else { return }
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
                frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        }
    }
}
