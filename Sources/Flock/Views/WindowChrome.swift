import AppKit
import FlockCore
import SwiftUI

extension View {
    /// A fill confined to this view's own frame. The shape-style `.background`
    /// extends into safe areas, and everything within the system title bar's
    /// height (taller than `ChromeMetrics.TitleBar.height`) sits inside the top
    /// safe area, so that fill would paint up over the title bar.
    func boundedBackground<S: ShapeStyle>(_ style: S) -> some View {
        background(style, ignoresSafeAreaEdges: [])
    }
}

/// Takes the view's area out of the window's drag region. The system title bar
/// is taller than `ChromeMetrics.TitleBar.height`, so the top of the tab strip
/// sits inside it, and a hosting view reports `mouseDownCanMoveWindow` true:
/// without an opt-out there, a press at the top of the strip moves the window
/// instead of reaching the strip. It never takes a hit itself, so every press
/// still lands on the SwiftUI content above it.
struct WindowDragExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableView { NonDraggableView() }
    func updateNSView(_ nsView: NonDraggableView, context: Context) {}
}

final class NonDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The chrome title bar's own mouse handling. Content covers the system title
/// bar, so AppKit's double-click action never sees a click there: this view
/// performs the user's chosen double-click action itself and hands every other
/// press to the window drag.
struct TitleBarMouseArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarMouseView { TitleBarMouseView() }
    func updateNSView(_ nsView: TitleBarMouseView, context: Context) {}
}

final class TitleBarMouseView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        let defaults = UserDefaults.standard
        let action = TitleBarDoubleClickAction(
            action: defaults.string(forKey: TitleBarDoubleClickAction.actionKey),
            legacyMinimize: defaults.bool(forKey: TitleBarDoubleClickAction.legacyMinimizeKey)
        )
        switch action {
        case .zoom:
            window.performZoom(nil)
        case .fill:
            guard let screen = window.screen else { return }
            window.setFrame(screen.visibleFrame, display: true, animate: true)
        case .minimize:
            window.performMiniaturize(nil)
        case .doNothing:
            break
        }
    }
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

    private let buttons = WindowButtonCentering(barHeight: ChromeMetrics.TitleBar.height)

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
/// draws, as well as the window events that precede a relayout. AppKit can
/// also replace the buttons outright (a style mask change), so every pass
/// checks it is still observing the buttons the window has now. Full screen is
/// left alone: there the buttons live in the system's reveal bar.
@MainActor
final class WindowButtonCentering {
    private final class WeakButton {
        weak var button: NSButton?
        init(_ button: NSButton) { self.button = button }
    }

    private let barHeight: CGFloat
    private weak var window: NSWindow?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var buttonObservers: [NSObjectProtocol] = []
    private var observedButtons: [WeakButton] = []

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
    }

    deinit {
        for observer in windowObservers + buttonObservers {
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
            windowObservers.append(center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        apply()
    }

    func detach() {
        for observer in windowObservers + buttonObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        buttonObservers = []
        observedButtons = []
        window = nil
    }

    private func isObserving(_ buttons: [NSButton]) -> Bool {
        observedButtons.count == buttons.count && zip(observedButtons, buttons).allSatisfy { $0.button === $1 }
    }

    private func observe(_ buttons: [NSButton]) {
        let center = NotificationCenter.default
        for observer in buttonObservers {
            center.removeObserver(observer)
        }
        buttonObservers = buttons.map { button in
            button.postsFrameChangedNotifications = true
            return center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        observedButtons = buttons.map(WeakButton.init)
    }

    func apply() {
        guard let window else { return }
        let buttons = Self.buttons(of: window)
        if !isObserving(buttons) {
            observe(buttons)
        }
        guard !window.styleMask.contains(.fullScreen) else { return }
        for button in buttons {
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
