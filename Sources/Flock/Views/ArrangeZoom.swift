import AppKit
import Carbon.HIToolbox
import FlockCore
import SwiftUI

/// Where an island is drawn on its way into or out of a zoom: laid out once
/// at its zoomed size and carried by a scale and an offset alone, so the
/// whole transition is composited and nothing inside it lays out again.
/// `progress` 0 is the island's place in the grid, 1 the full canvas.
struct ArrangeZoomFrame: ViewModifier {
    let source: CGRect
    let target: CGRect
    let progress: CGFloat

    func body(content: Content) -> some View {
        let scaleX = target.width > 0 ? source.width / target.width : 1
        let scaleY = target.height > 0 ? source.height / target.height : 1
        content
            .scaleEffect(
                x: scaleX + (1 - scaleX) * progress, y: scaleY + (1 - scaleY) * progress, anchor: .topLeading
            )
            .offset(
                x: (source.minX - target.minX) * (1 - progress),
                y: (source.minY - target.minY) * (1 - progress)
            )
    }
}

/// The grid behind a zoom: faded and drawn back a little, `progress` 1
/// being fully gone.
struct ArrangeRecede: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .scaleEffect(1 - (1 - ChromeMetrics.Grid.zoomRecedeScale) * progress)
    }
}

enum ArrangeZoomMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? ChromeMetrics.Grid.zoomCrossfadeDuration : ChromeMetrics.Grid.zoomDuration)
    }

    /// Opaque throughout: it starts as a cover over its own place in the
    /// grid, so fading it in would show that island twice. Reduce Motion
    /// keeps the change and drops the travel: a crossfade.
    static func zoomed(from source: CGRect?, to target: CGRect, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion, let source, target.width > 0, target.height > 0 else { return .opacity }
        return .modifier(
            active: ArrangeZoomFrame(source: source, target: target, progress: 0),
            identity: ArrangeZoomFrame(source: source, target: target, progress: 1)
        )
    }

    static func receding(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .modifier(active: ArrangeRecede(progress: 1), identity: ArrangeRecede(progress: 0))
    }
}

private struct ArrangeZoomPreviewKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Draws a zoom held part of the way in, grid and island both on screen,
    /// for the render tests: an offscreen snapshot sees only the model state
    /// of a running animation, never a frame of it.
    var arrangeZoomPreviewProgress: CGFloat? {
        get { self[ArrangeZoomPreviewKey.self] }
        set { self[ArrangeZoomPreviewKey.self] = newValue }
    }
}

/// An island header's zoom control: zoom in from the grid, shown while the
/// island is hovered, or the way back out on a zoomed island, with its key.
struct ArrangeZoomControl: View {
    let theme: Theme
    let isZoomed: Bool
    let workspace: WorkspaceID
    let action: () -> Void

    @State private var isHovering = false

    private typealias G = ChromeMetrics.Grid

    var body: some View {
        Button(action: action) {
            HStack(spacing: G.zoomControlSpacing) {
                if isZoomed {
                    Text("esc").font(ChromeType.arrangeZoomKey).foregroundStyle(theme.textLabel)
                }
                Image(systemName: isZoomed ? "xmark" : "arrow.up.left.and.arrow.down.right")
                    .font(ChromeType.arrangeZoomSymbol)
                    .foregroundStyle(isHovering ? theme.textStrong : theme.textLabel)
            }
            .padding(.horizontal, G.zoomControlHorizontalPadding)
            .frame(minWidth: G.zoomControlSize, minHeight: G.zoomControlSize)
            .background(
                RoundedRectangle(cornerRadius: ChromeRadius.control)
                    .fill(isZoomed || isHovering ? theme.tabRest : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isZoomed ? "Zoom out (esc)" : "Zoom into this workspace (space)")
        .accessibilityLabel(isZoomed ? "Zoom out" : "Zoom into workspace")
        .accessibilityIdentifier(isZoomed ? "flock.grid.unzoom" : "flock.grid.zoom.\(workspace.rawValue)")
    }
}

/// Space zooms Arrange into the current workspace and back out, before the
/// window's first responder sees the key: Arrange opens over a terminal that
/// may still hold it, and a SwiftUI focus request is dropped while it does.
struct ArrangeKeyMonitor: NSViewRepresentable {
    /// Answers whether the key was taken.
    let space: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.space = space
    }

    final class MonitorView: NSView {
        var space: () -> Bool = { false }
        nonisolated(unsafe) private var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window, Int(event.keyCode) == kVK_Space,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return event }
                return self.space() ? nil : event
            }
        }
    }
}
