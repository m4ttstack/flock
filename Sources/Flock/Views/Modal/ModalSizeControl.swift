import FlockCore
import SwiftUI

/// One button per modal size, each a box that grows with the size it stands
/// for; the selected one is filled.
struct ModalSizeControl: View {
    let theme: Theme
    let selected: ModalSize
    let onSelect: (ModalSize) -> Void

    private typealias Metrics = ChromeMetrics.Modal.SizeControl

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ForEach(ModalSize.allCases, id: \.self) { size in
                Button { onSelect(size) } label: {
                    glyph(size)
                        .frame(width: Metrics.buttonSide, height: Metrics.buttonSide)
                        .hoverWash(theme, cornerRadius: ChromeMetrics.Modal.TitleRow.buttonCornerRadius)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(size.displayName)
                .accessibilityLabel("Modal size: \(size.displayName)")
                .accessibilityIdentifier("flock.modal.size.\(size.rawValue)")
                .accessibilityAddTraits(size == selected ? .isSelected : [])
            }
        }
    }

    private func glyph(_ size: ModalSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.glyphCornerRadius)
        let glyphSize = Metrics.glyphSize(size)
        return ZStack {
            if size == selected {
                shape.fill(theme.accent)
            } else {
                shape.strokeBorder(theme.textDim, lineWidth: Metrics.glyphLineWidth)
            }
        }
        .frame(width: glyphSize.width, height: glyphSize.height)
    }
}
