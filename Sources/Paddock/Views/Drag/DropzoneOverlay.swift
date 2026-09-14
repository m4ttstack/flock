import PaddockCore
import SwiftUI

/// The canvas's edge-band preview: the rects the tab would have once the drop
/// lands, with the incoming pane's filled. Drawn in the canvas's own space
/// (the same space `CanvasGeometry` produces) and cross-faded whole as the
/// target moves, so nothing here ever animates a layout.
///
/// The live drag state is read HERE rather than passed down from
/// `PaneCanvas`: the target changes on every pointer move, and reading it in
/// the canvas's own body would re-evaluate every pane cell that often.
struct DropzoneOverlay: View {
    let theme: Theme
    let layout: LayoutSnapshot?
    let exported: ExportedLayoutDescription?
    let grid: CanvasGrid
    let dividerThickness: CGFloat

    @Environment(DragCoordinator.self) private var drag

    var body: some View {
        let preview = preview
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
    }

    private var preview: DropPreviewFrames? {
        guard let layout else { return nil }
        return DropPreview.frames(
            target: drag.target,
            dragging: drag.activeSubject,
            layout: layout,
            exported: exported,
            grid: grid,
            dividerThickness: dividerThickness
        )
    }

    private func shapes(for preview: DropPreviewFrames) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(preview.others.enumerated()), id: \.offset) { _, frame in
                outline(in: frame)
            }
            filled(in: preview.incoming)
        }
    }

    /// `DropPreviewFrames` already carries the pane-box inset, so these are
    /// drawn exactly as given.
    private func outline(in box: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .strokeBorder(theme.overlay0, lineWidth: 1)
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
    }

    private func filled(in box: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(theme.accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent, lineWidth: 2))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
    }
}
