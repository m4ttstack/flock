import AppKit
import SwiftUI

/// Registers the Settings window with `FlockWindow`. Its size is SwiftUI's:
/// the toolbar tabs fit the window to each tab's content as it is shown.
struct SettingsWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> RegisteringView { RegisteringView() }
    func updateNSView(_ view: RegisteringView, context: Context) {}

    final class RegisteringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { FlockWindow.settings = window }
        }
    }
}
