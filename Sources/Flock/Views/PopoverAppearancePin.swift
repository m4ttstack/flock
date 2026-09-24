import AppKit
import SwiftUI

/// `.popover`'s own arrow and bezel draw from the AppKit window's
/// appearance, not from anything a SwiftUI colour scheme modifier reaches,
/// so a dark-themed popover otherwise gets the system's light arrow notched
/// against its own dark panel. Pinning the window directly (the same
/// `view.window` seam `ChatPopoverEscMonitor` uses) is the one place this is
/// reachable at all; `isDark` comes from the theme's own `panelBg`
/// luminance, never hardcoded, so a light built-in theme still gets its own
/// light chrome.
struct PopoverAppearancePin: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(isDark, to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.apply(isDark, to: nsView)
    }

    @MainActor
    private static func apply(_ isDark: Bool, to view: NSView) {
        view.window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}
