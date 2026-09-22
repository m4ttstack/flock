import AppKit
import FlockCore
import SwiftUI
import XCTest

/// SwiftUI's `.popover` draws its own arrow and bezel from the AppKit
/// window's own appearance, which otherwise stays whatever the system is
/// set to -- so a dark-themed popover got the system's light chrome no
/// matter how dark its content painted. `ChatPopoverAppearancePin` reaches
/// the popover's window through the same `view.window` seam
/// `ChatPopoverEscMonitor` already uses, and this proves it lands: the
/// window's own `appearance` follows the theme's `panelBg` luminance in
/// both directions, not a hardcoded direction.
@MainActor
final class ChatPopoverAppearanceTests: XCTestCase {
    private func popoverWindow(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) { view }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makePopover(theme: Theme) -> ChatPopover {
        ChatPopover(
            theme: theme, status: nil, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
    }

    func testADarkThemedPopoverPinsItsWindowToDarkAqua() async {
        let window = popoverWindow(makePopover(theme: .tokyoNight))
        await settle(window)
        defer { window.close() }
        XCTAssertEqual(window.appearance?.name, .darkAqua, "tokyo-night's dark panelBg must pin the popover window to darkAqua")
    }

    func testALightThemedPopoverPinsItsWindowToAqua() async {
        let window = popoverWindow(makePopover(theme: Theme(.tokyoNightDay)))
        await settle(window)
        defer { window.close() }
        XCTAssertEqual(window.appearance?.name, .aqua, "tokyo-night-day's light panelBg must pin the popover window to aqua, not stay dark")
    }
}
