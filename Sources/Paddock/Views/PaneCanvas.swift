import PaddockCore
import SwiftUI

/// The pane canvas for the selected tab: `CanvasGeometry` scales the layout's
/// cell rects to the available size, and each pane renders inset by half the
/// 6px gutter so adjacent cells read as separated.
struct PaneCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?

    private static let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let layout {
                    let geometry = CanvasGeometry(layout: layout, in: proxy.size, dividerThickness: Self.dividerThickness)
                    ForEach(layout.panes, id: \.paneID) { paneRect in
                        if let pane = viewModel.model?.panes[paneRect.paneID],
                           let frame = geometry.paneFrames[paneRect.paneID] {
                            PaneCellView(
                                theme: theme,
                                pane: pane,
                                // The view-model's resolved focus, not
                                // `layout.focusedPaneID` (a `pane.focus` jump
                                // never touches the layout snapshot, only
                                // `model.focusedPaneID`) and not
                                // `model.focusedPaneID` directly (that only
                                // updates once herdr's echo lands, tens of ms
                                // after the click -- `resolvedFocusedPaneID`
                                // paints the optimistic prediction instead).
                                isFocused: pane.paneID == viewModel.resolvedFocusedPaneID,
                                lastLine: viewModel.lastLine(for: pane)
                            )
                            .frame(
                                width: max(0, frame.width - Self.dividerThickness),
                                height: max(0, frame.height - Self.dividerThickness)
                            )
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityIdentifier("paddock.canvas.pane.\(pane.paneID.rawValue)")
                            .onTapGesture {
                                Task { await viewModel.jumpToHerdr(pane: pane.paneID) }
                            }
                        }
                    }
                } else {
                    Text("No tab selected")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.overlay0)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .padding(10)
        .background(theme.windowBg)
    }
}
