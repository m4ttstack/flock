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

    /// The view's alpha, not its layer's opacity: AppKit owns a layer-backed
    /// view's root layer and resets that opacity from the alpha.
    func updateNSView(_ view: PaneShadeView, context: Context) {
        view.alphaValue = veil
    }
}

final class PaneShadeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// Set here, where AppKit asks for it, rather than once at creation: the
    /// root layer of a layer-backed view is AppKit's, and it can be rebuilt.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never takes a click: the pane under it keeps every one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
