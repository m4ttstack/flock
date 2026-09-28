import AppKit
import SwiftUI

/// Makes the Settings window resizable in height only and opens it tall
/// enough for every section. SwiftUI sizes a Settings window to its content,
/// and a grouped Form scrolls, so it has no height of its own to offer.
struct SettingsWindowSizer: NSViewRepresentable {
    static let width: CGFloat = 500
    static let minHeight: CGFloat = 320
    static let openHeight: CGFloat = 700

    func makeNSView(context: Context) -> SizerView { SizerView() }
    func updateNSView(_ view: SizerView, context: Context) {}

    final class SizerView: NSView {
        private weak var sized: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== sized else { return }
            sized = window
            // After SwiftUI's own first sizing pass, which would undo it.
            DispatchQueue.main.async {
                window.styleMask.insert(.resizable)
                window.contentMinSize = NSSize(width: SettingsWindowSizer.width, height: SettingsWindowSizer.minHeight)
                window.contentMaxSize = NSSize(width: SettingsWindowSizer.width, height: .greatestFiniteMagnitude)
                let height = min(SettingsWindowSizer.openHeight, (window.screen?.visibleFrame.height ?? SettingsWindowSizer.openHeight) - 40)
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: SettingsWindowSizer.width, height: height)))
                frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        }
    }
}
