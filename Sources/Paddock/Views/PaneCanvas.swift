import PaddockCore
import SwiftUI

/// The pane canvas for the selected tab: `CanvasGeometry.resolved` reads
/// herdr's own `layout.export` split tree when the view-model has one cached
/// for this tab, falling back to rect derivation otherwise, then scales the
/// result to the available size; each pane renders inset by half the 6px
/// gutter so adjacent cells read as separated.
struct PaneCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?

    private static let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let layout {
                    let geometry = CanvasGeometry.resolved(
                        layout: layout,
                        exported: viewModel.exportedLayout(for: layout.tabID),
                        in: proxy.size,
                        dividerThickness: Self.dividerThickness
                    )
                    ForEach(layout.panes, id: \.paneID) { paneRect in
                        if let pane = viewModel.model?.panes[paneRect.paneID],
                           let frame = geometry.paneFrames[paneRect.paneID] {
                            PaneCellView(
                                theme: theme,
                                viewModel: viewModel,
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
                                lastLine: viewModel.lastLine(for: pane),
                                // The pane's real terminal cell size: the
                                // layout's own `CellRect`, never `frame`
                                // (that's a scaled pixel rect for on-screen
                                // placement, not the observe/TerminalView
                                // dims contract).
                                cols: paneRect.rect.width,
                                rows: paneRect.rect.height
                            )
                            .frame(
                                width: max(0, frame.width - Self.dividerThickness),
                                height: max(0, frame.height - Self.dividerThickness)
                            )
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityIdentifier("paddock.canvas.pane.\(pane.paneID.rawValue)")
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
