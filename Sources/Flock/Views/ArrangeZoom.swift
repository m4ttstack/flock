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

/// Arrange's canvas: the grid first, then the zoomed island when there is
/// one. The grid is proposed the same size whether or not a zoom covers it,
/// so a zoom never lays it out again; the canvas measures as the zoomed
/// island while there is one, so the grid behind adds no scroll.
struct ArrangeCanvasLayout: Layout {
    let isZoomed: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let grid = subviews.first else { return .zero }
        let measured = isZoomed && subviews.count > 1 ? subviews[1] : grid
        return measured.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        }
    }

    /// None: the default merges every subview's guides, which measures the
    /// whole grid again on a pass that only moved the zoomed island.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        nil
    }
}

/// The grid behind a zoom: faded and drawn back a little, `progress` 1
/// being fully gone. Reduce Motion keeps the fade alone.
struct ArrangeRecede: ViewModifier {
    let progress: CGFloat
    var travels = true

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .scaleEffect(travels ? 1 - (1 - ChromeMetrics.Grid.zoomRecedeScale) * progress : 1)
    }
}

enum ArrangeZoomMotion {
    static func duration(reduceMotion: Bool) -> Double {
        reduceMotion ? ChromeMetrics.Grid.zoomCrossfadeDuration : ChromeMetrics.Grid.zoomDuration
    }

    static func animation(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: duration(reduceMotion: reduceMotion))
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
}

extension View {
    /// Stops the zoom's own animation at the zoomed island's edge: the
    /// transition carries the island whole, and inside it every view would
    /// otherwise animate its frame from where it was just built to that same
    /// place, which costs the zoom's first frame and changes nothing drawn.
    /// Any other animation passes through.
    func arrangeZoomStill(reduceMotion: Bool) -> some View {
        transaction { transaction in
            if transaction.animation == ArrangeZoomMotion.animation(reduceMotion: reduceMotion) {
                transaction.animation = nil
            }
        }
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

/// Which of Arrange's two layers an item is drawn in: the grid, which stays
/// built behind a zoom, or the zoomed island in front of it. Each reports
/// its frames apart, so a zoom changes which set a drop reads and nothing
/// in the grid has to report again.
enum ArrangeLayer: Sendable {
    case grid
    case zoomed
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
                Image(systemName: isZoomed ? "xmark" : "arrow.up.left.and.arrow.down.right")
                    .font(ChromeType.arrangeZoomSymbol)
                Text(isZoomed ? "Close" : "Zoom").font(ChromeType.arrangeZoomLabel)
                if isZoomed {
                    Text("esc").font(ChromeType.arrangeZoomKey).foregroundStyle(theme.textLabel)
                }
            }
            .foregroundStyle(theme.textStrong)
            .padding(.horizontal, G.zoomControlHorizontalPadding)
            .frame(minWidth: G.zoomControlSize, minHeight: G.zoomControlSize)
            .background(
                RoundedRectangle(cornerRadius: ChromeRadius.control)
                    .fill(isHovering ? theme.selection : theme.tabRest)
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

/// Space zooms Arrange into the current workspace and back out, and Return
/// opens the selected mini pane, before the window's first responder sees
/// the key: Arrange opens over a terminal that may still hold it, and a
/// SwiftUI focus request is dropped while it does.
struct ArrangeKeyMonitor: NSViewRepresentable {
    /// Each answers whether the key was taken.
    let space: () -> Bool
    let open: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.space = space
        view.open = open
    }

    final class MonitorView: NSView {
        var space: () -> Bool = { false }
        var open: () -> Bool = { false }
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
                guard let self, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return event }
                switch Int(event.keyCode) {
                case kVK_Space: return self.space() ? nil : event
                case kVK_Return, kVK_ANSI_KeypadEnter: return self.open() ? nil : event
                default: return event
                }
            }
        }
    }
}

/// Opening a pane from Arrange in Workspaces: a double-click on its mini
/// pane, or Return on the selected one. The tab is selected before the grid
/// closes, so the window never draws the previously selected tab in between.
@MainActor
enum ArrangeOpen {
    static func open(tab: TabID, pane: PaneID?, viewModel: SessionViewModel, drag: DragCoordinator) {
        viewModel.forgetWorkspacesFocus()
        viewModel.select(tab: tab)
        drag.closeGrid()
        Task {
            await viewModel.jumpToHerdr(tab: tab)
            if let pane { await viewModel.jumpToHerdr(pane: pane) }
        }
    }
}
