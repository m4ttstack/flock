import AppKit
import SwiftUI

/// Registers the Settings window with `FlockWindow` and fits it to the shown
/// tab: the settings' width, and the tab's measured height, its top edge held
/// still. Left to itself the window keeps whatever frame it last had, an
/// earlier resizable build's included, and the tab floats in the middle.
struct SettingsWindowRegistration: NSViewRepresentable {
    let width: CGFloat
    /// The shown tab's height; nil until it has been measured.
    let height: CGFloat?

    func makeNSView(context: Context) -> FittingView { FittingView() }

    func updateNSView(_ view: FittingView, context: Context) {
        view.fit(width: width, height: height)
    }

    final class FittingView: NSView {
        private var size: (width: CGFloat, height: CGFloat?) = (0, nil)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            FlockWindow.settings = window
            window.styleMask.remove(.resizable)
            fit(width: size.width, height: size.height)
        }

        func fit(width: CGFloat, height: CGFloat?) {
            size = (width, height)
            guard width > 0, let height else { return }
            // After SwiftUI's own sizing pass for this update, which would
            // undo it.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                let content = window.contentRect(forFrameRect: window.frame)
                guard abs(content.width - width) > 0.5 || abs(content.height - height) > 0.5 else { return }
                var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
                frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true, animate: window.isVisible)
            }
        }
    }
}
