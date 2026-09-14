import PaddockCore
import SwiftUI

/// The pane canvas for the selected tab: herdr's split geometry read as
/// PROPORTIONS of the tab's cell area and stretched to fill the window, so
/// the canvas is always full and paddock's own boxes decide how big each pane
/// really is. Inside a box the surface is an exact whole-cell grid at the
/// Terminal Text size, with the sub-cell remainder left as padding.
///
/// `CanvasGeometry.resolved` reads herdr's own `layout.export` split tree when
/// the view-model has one cached for this tab, falling back to rect derivation
/// otherwise; each pane is inset by half the 6px gutter so adjacent cells read
/// as separated.
struct PaneCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?

    @Environment(TerminalTextSizeStore.self) private var terminalTextSizeStore
    @Environment(\.displayScale) private var displayScale

    private static let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let scale = displayScale > 0 ? displayScale : 2
            let fontSize = terminalTextSizeStore.points
            let cell = TerminalCellMetrics.cell(fontSize: fontSize, scale: scale)
            // The canvas's own window origin: a box snapped as if the canvas
            // began at the window's corner would still leave the surface on a
            // fractional device pixel.
            let grid = CanvasGrid(canvas: proxy.size, phase: proxy.frame(in: .global).origin, displayScale: scale)
            ZStack(alignment: .topLeading) {
                if let layout {
                    let geometry = CanvasGeometry.resolved(
                        layout: layout,
                        exported: viewModel.exportedLayout(for: layout.tabID),
                        grid: grid,
                        dividerThickness: Self.dividerThickness
                    )
                    ForEach(layout.panes, id: \.paneID) { paneRect in
                        if let pane = viewModel.model?.panes[paneRect.paneID],
                           let frame = geometry.paneFrames[paneRect.paneID] {
                            let box = PaneBox.frame(in: frame, dividerThickness: Self.dividerThickness)
                            let fit = SurfaceGrid.fit(inner: Self.innerSize(of: box.size), cell: cell)
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
                                grid: PTYSize(cols: fit.cols, rows: fit.rows),
                                surfaceSize: fit.size,
                                fontSizePoints: fontSize
                            )
                            // Placed by offset rather than `.position`, which
                            // centers on a midpoint and so halves the box size:
                            // this keeps the snapped origin exactly as
                            // `CanvasGrid` produced it.
                            .frame(width: box.width, height: box.height, alignment: .topLeading)
                            .offset(x: box.minX, y: box.minY)
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

    /// What is left of a box for the terminal itself, once the legend band and
    /// the content insets are taken out.
    private static func innerSize(of box: CGSize) -> CGSize {
        let chrome = PaneCellView.chrome
        return CGSize(width: max(0, box.width - chrome.width), height: max(0, box.height - chrome.height))
    }
}
