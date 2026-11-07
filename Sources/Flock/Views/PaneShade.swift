import AppKit
import SwiftUI

/// Darkens a pane without focus: a black veil in a view of its own over the
/// whole box. SwiftUI draws beneath the terminal's surface view, so a SwiftUI
/// scrim only reaches the ground the terminal leaves clear; a layer inside the
/// surface stops at its edge and leaves the header and padding bright.
///
/// The colour drain is not here: a blend filter only sees what lies beneath it
/// in its own layer tree, so over another view it paints grey. That lives on
/// the surface (`GhosttySurfaceView.isDrained`).
struct PaneShade: NSViewRepresentable {
    /// How much black lies over the pane, 0 to 1.
    let veil: Double

    func makeNSView(context: Context) -> PaneShadeView { PaneShadeView() }

    func updateNSView(_ view: PaneShadeView, context: Context) {
        view.setVeil(veil)
    }
}

/// The veil is a sublayer, never the root layer's own fill or opacity: AppKit
/// owns a layer-backed view's root layer and resets both.
final class PaneShadeView: NSView {
    private let veilLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        veilLayer.backgroundColor = NSColor.black.cgColor
        veilLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(veilLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVeil(_ veil: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veilLayer.opacity = Float(veil)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veilLayer.frame = bounds
        CATransaction.commit()
    }

    /// Never takes a click: the pane under it keeps every one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
