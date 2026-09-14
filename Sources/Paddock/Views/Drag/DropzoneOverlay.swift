import PaddockCore
import SwiftUI

/// The canvas's edge-band preview: the rects the tab would have once the drop
/// lands, with the incoming pane's filled. Drawn in the canvas's own space
/// (the same space `CanvasGeometry` produces) and cross-faded whole as the
/// target moves, so nothing here ever animates a layout.
struct DropzoneOverlay: View {
    let theme: Theme
    let preview: DropPreviewFrames?
    var dividerThickness: CGFloat = 6

    var body: some View {
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

    private func shapes(for preview: DropPreviewFrames) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(preview.others.enumerated()), id: \.offset) { _, frame in
                outline(in: frame)
            }
            filled(in: preview.incoming)
        }
    }

    /// Inset the same way a real pane cell is, so a previewed rect sits
    /// exactly where the cell that lands there will.
    private func box(_ frame: CGRect) -> CGRect {
        PaneBox.frame(in: frame, dividerThickness: dividerThickness)
    }

    private func outline(in frame: CGRect) -> some View {
        let box = box(frame)
        return RoundedRectangle(cornerRadius: 9)
            .strokeBorder(theme.overlay0, lineWidth: 1)
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
    }

    private func filled(in frame: CGRect) -> some View {
        let box = box(frame)
        return RoundedRectangle(cornerRadius: 9)
            .fill(theme.accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent, lineWidth: 2))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
    }
}
