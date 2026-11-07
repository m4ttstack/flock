import AppKit
import SwiftUI

/// Sets a pane without focus back: drains its colour and darkens it. A view
/// of its own over the whole box, because SwiftUI draws beneath the
/// terminal's surface view (a SwiftUI scrim only reaches the ground the
/// terminal leaves clear) while a layer inside the surface stops at its
/// edge and leaves the header and padding bright.
struct PaneShade: NSViewRepresentable {
    /// How much colour goes, 0 to 1.
    let drain: Double
    /// How much black lies over it, 0 to 1.
    let veil: Double

    func makeNSView(context: Context) -> PaneShadeView { PaneShadeView() }

    func updateNSView(_ view: PaneShadeView, context: Context) {
        view.apply(drain: drain, veil: veil)
    }
}

final class PaneShadeView: NSView {
    private let drainLayer = CALayer()
    private let veilLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        drainLayer.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        drainLayer.compositingFilter = CIFilter(name: "CISaturationBlendMode")
        veilLayer.backgroundColor = NSColor.black.cgColor
        for sublayer in [drainLayer, veilLayer] {
            sublayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(drain: Double, veil: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drainLayer.opacity = Float(drain)
        veilLayer.opacity = Float(veil)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drainLayer.frame = bounds
        veilLayer.frame = bounds
        CATransaction.commit()
    }

    /// Never takes a click: the pane under it keeps every one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
