import FlockCore
import AppKit
import SwiftUI

extension Theme {
    /// The ground of a panel hung over the terminal: the terminal's own,
    /// lifted just enough to read as a layer and keep its labels legible.
    var panelSurface: Color {
        let isDark = !ChromeRoles.isLight(panelBg: palette.panelBg)
        return Color(palette.terminalGround.mixed(
            with: isDark ? RGB(255, 255, 255) : RGB(0, 0, 0), amount: ChromeMetrics.AnchoredPanel.surfaceLift
        ))
    }
}

extension View {
    /// A popover of flock's own: a borderless panel hung from this view's
    /// bottom-right corner, with a short fade-and-drop in and a quicker fade
    /// out. AppKit's popover offers its own animation or none, its own corner
    /// and an arrow, none of which the quiet chrome wants.
    ///
    /// The panel is a separate window, so the content does not inherit this
    /// view's environment: whatever it reads must be set on it before it is
    /// handed over.
    func anchoredPanel<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        background(AnchoredPanelHost(isPresented: isPresented, content: { AnyView(content()) }))
    }
}

private struct AnchoredPanelHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> AnyView

    func makeNSView(context: Context) -> AnchoredPanelAnchor { AnchoredPanelAnchor() }

    func updateNSView(_ anchor: AnchoredPanelAnchor, context: Context) {
        anchor.onDismiss = { isPresented = false }
        if isPresented {
            anchor.present(content())
        } else {
            anchor.dismiss()
        }
    }

    static func dismantleNSView(_ anchor: AnchoredPanelAnchor, coordinator: ()) {
        anchor.dismiss(animated: false)
    }
}

/// Takes the keyboard, so the Slack form's fields and the popover's own
/// Esc monitor work, without a title bar or a frame.
private final class AnchoredPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AnchoredPanelAnchor: NSView {
    var onDismiss: (() -> Void)?

    private typealias M = ChromeMetrics.AnchoredPanel

    private var panel: AnchoredPanelWindow?
    private var host: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var isClosing = false

    func present(_ content: AnyView) {
        let sized = AnyView(content.onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            self?.fit(size)
        })
        if let host, panel != nil, !isClosing {
            host.rootView = sized
            return
        }
        open(sized)
    }

    private func open(_ content: AnyView) {
        guard let parent = window else { return }
        dismiss(animated: false)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let panel = AnchoredPanelWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Flat, like the quick launch strip: the system shadow lays a bright
        // edge around a dark window.
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.contentView = host
        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.host = host

        let final = frame(for: size)
        panel.setFrame(final.offsetBy(dx: 0, dy: M.dropDistance), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.openDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        watchForDismissal()
    }

    /// Keeps the top-right corner pinned to the anchor as the content's
    /// height changes (a drill-in route, a hint line).
    private func fit(_ size: CGSize) {
        guard let panel, !isClosing, size.width > 0, size.height > 0 else { return }
        panel.setFrame(frame(for: size), display: true)
    }

    private func frame(for size: CGSize) -> CGRect {
        guard let window else { return CGRect(origin: .zero, size: size) }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        return CGRect(x: anchor.maxX - size.width, y: anchor.minY - M.gap - size.height, width: size.width, height: size.height)
    }

    func dismiss(animated: Bool = true) {
        guard let panel, !isClosing else { return }
        stopWatching()
        guard animated else {
            tearDown(panel)
            return
        }
        isClosing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.closeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.tearDown(panel) }
        }
    }

    private func tearDown(_ panel: NSPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if self.panel === panel {
            self.panel = nil
            host = nil
        }
        isClosing = false
    }

    /// A press anywhere outside the panel, or the app losing focus, closes
    /// it, as a transient popover would.
    private func watchForDismissal() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, let panel = self.panel, event.window !== panel {
                self.requestDismiss()
            }
            return event
        }
        if let monitor { monitors.append(monitor) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestDismiss() }
        }
    }

    private func requestDismiss() {
        onDismiss?()
        dismiss()
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
