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

/// Every popover opens and closes at once, without AppKit's grow-and-fade,
/// and without its arrow. `willShow` arrives before the show animation and
/// before the frame is drawn, the last moment either setting still applies.
///
/// The arrow switch is AppKit's own unpublished `shouldHideAnchor`, set only
/// where the running system answers to it, so a later macOS without it keeps
/// the arrow rather than crashing.
@MainActor
enum PopoverSnap {
    private static var observers: [NSObjectProtocol] = []
    private static let hideAnchor = Selector(("setShouldHideAnchor:"))

    static func install() {
        guard observers.isEmpty else { return }
        // At close too: SwiftUI can hand the same popover back with its
        // animation on, and the window keeps a fade of its own.
        for name in [NSPopover.willShowNotification, NSPopover.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let popover = note.object as? NSPopover
                MainActor.assumeIsolated { snap(popover) }
            })
        }
    }

    private static func snap(_ popover: NSPopover?) {
        guard let popover else { return }
        popover.animates = false
        popover.contentViewController?.view.window?.animationBehavior = .none
        if popover.responds(to: hideAnchor) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
    }
}
