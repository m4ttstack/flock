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
    static let name = "paddock.drag"
    static var coordinateSpace: CoordinateSpace { .named(name) }
}

private struct DragFrameReporter: ViewModifier {
    let report: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: DragSpace.coordinateSpace)
                Color.clear
                    .onAppear { report(frame) }
                    .onChange(of: frame) { _, new in report(new) }
            }
        }
    }
}

extension View {
    /// Publishes this view's frame in the drag space whenever it changes.
    func reportsDragFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        modifier(DragFrameReporter(report: report))
    }
}
