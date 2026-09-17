import SwiftUI

/// The one coordinate space every drag frame and every drag point lives in:
/// the main window's root view, top-left origin, points. `MainWindow` names
/// it; each surface reports its own frame in it, and `DropSurfaces` is
/// assembled from those frames alone.
///
/// AppKit pane bodies are the only other coordinate system involved. They
/// report a point in their own space with the origin flipped to top-left, and
/// the SwiftUI wrapper adds the body's origin in THIS space -- that addition
/// is the single conversion between the two systems in the whole drag layer.
enum DragSpace {
    static let name = "flock.drag"
    static var coordinateSpace: CoordinateSpace { .named(name) }

    /// The scrolled content of the tab strip and the workspace rail. Items
    /// report their frames here, where scrolling never moves them; the
    /// content's own origin in the drag space places them on screen.
    static let stripContent = "flock.drag.strip-content"
    static let railContent = "flock.drag.rail-content"
    static let gridContent = "flock.drag.grid-content"

    /// The pane canvas's own space, which every `CanvasGeometry` rect is
    /// stated in before the canvas offsets a copy into the drag space. A
    /// divider gesture reads its pointer here so the value cannot depend on
    /// where the band it is dragging currently sits.
    static let canvasContent = "flock.drag.canvas-content"
}

/// An `NSView` laid out at exactly the drag space's frame, handed to the
/// coordinator so a raw AppKit event location can be converted into drag space
/// by asking AppKit rather than by assuming where the SwiftUI root sits inside
/// the window. Applied as the background of the very view that names the
/// space, so the two frames are the same rect by construction.
struct DragSpaceAnchor: NSViewRepresentable {
    let coordinator: DragCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        coordinator.spaceAnchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        coordinator.spaceAnchor = nsView
    }
}

private struct FrameReporter: ViewModifier {
    let space: CoordinateSpace
    let report: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: space)
                Color.clear
                    .onAppear { report(frame) }
                    .onChange(of: frame) { _, new in report(new) }
            }
        }
    }
}

/// A scroll view's offset along one axis and the furthest it can go.
private struct ScrollExtent: Equatable {
    let offset: CGFloat
    let maximum: CGFloat
}

extension View {
    /// Publishes this view's frame in the drag space whenever it changes.
    func reportsDragFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        modifier(FrameReporter(space: DragSpace.coordinateSpace, report: report))
    }

    /// Publishes this view's frame in the named space `name` whenever it
    /// changes.
    func reportsFrame(in name: String, _ report: @escaping (CGRect) -> Void) -> some View {
        modifier(FrameReporter(space: .named(name), report: report))
    }

    /// Applied to a scroll view: publishes its offset along `axis` and its
    /// maximum, zero while the content fits.
    func reportsScrollExtent(_ axis: Axis, _ report: @escaping (_ offset: CGFloat, _ maximum: CGFloat) -> Void) -> some View {
        onScrollGeometryChange(for: ScrollExtent.self) { geometry in
            switch axis {
            case .horizontal:
                ScrollExtent(offset: geometry.contentOffset.x, maximum: max(0, geometry.contentSize.width - geometry.containerSize.width))
            case .vertical:
                ScrollExtent(offset: geometry.contentOffset.y, maximum: max(0, geometry.contentSize.height - geometry.containerSize.height))
            }
        } action: { _, extent in
            report(extent.offset, extent.maximum)
        }
    }
}
