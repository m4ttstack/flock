import AppKit
import SwiftUI

/// The sides of a view that lie on its window's own edge.
struct WindowEdges: Equatable {
    var top = false
    var leading = false
    var bottom = false
    var trailing = false

    static let none = WindowEdges()
}

/// Reports which sides of the view it backs lie on the window's edge. A full
/// screen window reports none: it has no edge of its own and square corners.
struct WindowEdgeReporter: NSViewRepresentable {
    let report: (WindowEdges) -> Void

    func makeNSView(context: Context) -> WindowEdgeObserverView {
        WindowEdgeObserverView(report: report)
    }

    func updateNSView(_ nsView: WindowEdgeObserverView, context: Context) {
        nsView.report = report
        nsView.measure()
    }
}

final class WindowEdgeObserverView: NSView {
    var report: (WindowEdges) -> Void
    private var reported: WindowEdges?

    init(report: @escaping (WindowEdges) -> Void) {
        self.report = report
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        measure()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        measure()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        measure()
    }

    func measure() {
        var edges = WindowEdges.none
        if let window, let content = window.contentView, !window.styleMask.contains(.fullScreen) {
            let rect = convert(bounds, to: content)
            let outer = content.bounds
            let tolerance: CGFloat = 1
            let lowEdge = abs(rect.minY - outer.minY) <= tolerance
            let highEdge = abs(rect.maxY - outer.maxY) <= tolerance
            edges.top = content.isFlipped ? lowEdge : highEdge
            edges.bottom = content.isFlipped ? highEdge : lowEdge
            edges.leading = abs(rect.minX - outer.minX) <= tolerance
            edges.trailing = abs(rect.maxX - outer.maxX) <= tolerance
        }
        guard edges != reported else { return }
        reported = edges
        // Called from inside AppKit layout, where SwiftUI state must not change.
        DispatchQueue.main.async { [report] in report(edges) }
    }
}
