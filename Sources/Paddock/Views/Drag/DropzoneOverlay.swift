import PaddockCore
import SwiftUI

/// The canvas's edge-band preview: the rects the tab would have once the drop
/// lands, with the incoming pane's filled. Drawn in the canvas's own space
/// (the same space `CanvasGeometry` produces) and cross-faded whole as the
/// target moves, so nothing here ever animates a layout.
///
/// The live drag state is read HERE rather than passed down from `PaneCanvas`,
/// which keeps the canvas's own body off the drag's update path, and the
/// preview itself is recomputed only when its inputs change: the transform
/// walks a split tree and runs a full layout pass, which must not happen once
/// per pointer move.
struct DropzoneOverlay: View {
    let theme: Theme
    let layout: LayoutSnapshot?
    let exported: ExportedLayoutDescription?
    let grid: CanvasGrid
    let dividerThickness: CGFloat

    @Environment(DragCoordinator.self) private var drag
    @State private var preview: DropPreviewFrames?

    /// Everything the preview is a function of. Equal inputs mean the cached
    /// preview still stands, however many times this body is evaluated.
    private struct Inputs: Equatable {
        let target: DropTarget?
        let subject: DragSubject?
        let layout: LayoutSnapshot?
        let exported: ExportedLayoutDescription?
        let grid: CanvasGrid
        let dividerThickness: CGFloat
    }

    var body: some View {
        let inputs = Inputs(
            target: drag.target, subject: drag.activeSubject, layout: layout,
            exported: exported, grid: grid, dividerThickness: dividerThickness
        )
        ZStack(alignment: .topLeading) {
            if let preview {
                shapes(for: preview)
                    .id(preview)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: DragVisuals.previewCrossfadeDuration), value: preview)
        .onAppear { preview = Self.compute(inputs) }
        .onChange(of: inputs) { _, new in preview = Self.compute(new) }
    }

    private static func compute(_ inputs: Inputs) -> DropPreviewFrames? {
        guard let layout = inputs.layout else { return nil }
        return DropPreview.frames(
            target: inputs.target,
            dragging: inputs.subject,
            layout: layout,
            exported: inputs.exported,
            grid: inputs.grid,
            dividerThickness: inputs.dividerThickness
        )
    }

    /// Only the incoming rect is drawn. Outlining where every other pane
    /// lands puts a second rounded rect a few points from each pane's own
    /// border, which reads as a rendering fault rather than as a preview.
    private func shapes(for preview: DropPreviewFrames) -> some View {
        ZStack(alignment: .topLeading) {
            filled(in: preview.incoming)
        }
    }

    private func filled(in box: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(theme.accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent, lineWidth: 2))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
    }
}
