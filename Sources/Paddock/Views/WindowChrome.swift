import AppKit
import SwiftUI

/// Fixed chrome dimensions, shared by the SwiftUI chrome and the AppKit title
/// bar so the window buttons center on the same bar the views draw.
enum ChromeMetrics {
    static let titleBarHeight: CGFloat = 20
    static let railWidth: CGFloat = 150
    static let tabStripHeight: CGFloat = 28
    static let ruleWidth: CGFloat = 1
    static let canvasMargin: CGFloat = 5
}

/// Merges the system title bar into the content so the window buttons sit on
/// `TitleBar`'s chrome with no system strip above it. `.windowStyle(.hiddenTitleBar)`
/// alone still leaves a title bar safe-area inset, so `MainWindow` also ignores
/// the top safe area, and the window's own background is painted so nothing
/// shows through before the first frame draws.
struct TitlebarConfigurator: NSViewRepresentable {
    let windowBg: Color

    func makeNSView(context: Context) -> TitlebarHostView {
        let view = TitlebarHostView()
        view.windowBg = NSColor(windowBg)
        return view
    }

    func updateNSView(_ nsView: TitlebarHostView, context: Context) {
        nsView.windowBg = NSColor(windowBg)
    }
}

final class TitlebarHostView: NSView {
    var windowBg: NSColor = .clear {
        didSet { configure() }
    }

    private let buttons = WindowButtonCentering(barHeight: ChromeMetrics.titleBarHeight)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
    }

    private func configure() {
        guard let window else {
            buttons.detach()
            return
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = windowBg
        buttons.attach(to: window)
    }
}

/// Keeps the standard window buttons vertically centered in a title bar
/// shorter than the system's. AppKit lays the buttons out again on its own
/// schedule (a resize, a key change, leaving full screen), so each button's
/// own frame change is observed and corrected synchronously, before the pass
/// draws, as well as the window events that precede a relayout. Full screen is
/// left alone: there the buttons live in the system's reveal bar.
@MainActor
final class WindowButtonCentering {
    private let barHeight: CGFloat
    private weak var window: NSWindow?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else {
            apply()
            return
        }
        detach()
        self.window = window
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ]
        for name in windowEvents {
            observers.append(center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        for button in Self.buttons(of: window) {
            button.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        apply()
    }

    func detach() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        window = nil
    }

    func apply() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        for button in Self.buttons(of: window) {
            guard let container = button.superview else { continue }
            let y = Self.originY(
                buttonHeight: button.frame.height, barHeight: barHeight,
                containerHeight: container.bounds.height, containerIsFlipped: container.isFlipped
            )
            // The frame observer re-enters here on every move; an unchanged
            // origin is what ends that recursion.
            guard abs(button.frame.minY - y) > 0.01 else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y))
        }
    }

    static func buttons(of window: NSWindow) -> [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    /// The button container is pinned to the window's top edge, so the bar's
    /// center is measured down from the container's top.
    static func originY(buttonHeight: CGFloat, barHeight: CGFloat, containerHeight: CGFloat, containerIsFlipped: Bool) -> CGFloat {
        let top = (barHeight - buttonHeight) / 2
        return containerIsFlipped ? top : containerHeight - top - buttonHeight
    }
}
