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
/// otherwise; each pane box is inset from its layout frame (`PaneBox`) so
/// adjacent boxes leave exactly `DividerBand.gutter` between them.
struct PaneCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?

    @Environment(TerminalTextSizeStore.self) private var terminalTextSizeStore
    @Environment(DragCoordinator.self) private var drag
    @Environment(DividerDragCoordinator.self) private var dividerDrag
    @Environment(\.displayScale) private var displayScale

    private static let dividerThickness: CGFloat = DividerBand.gutter

    private static let canvasPadding: EdgeInsets = {
        let padding = PaneBox.canvasPadding(margin: ChromeMetrics.Canvas.margin, dividerThickness: dividerThickness)
        return EdgeInsets(
            top: padding.leadingAndTop, leading: padding.leadingAndTop,
            bottom: padding.trailingAndBottom, trailing: padding.trailingAndBottom
        )
    }()

    var body: some View {
        GeometryReader { proxy in
            let scale = displayScale > 0 ? displayScale : 2
            let fontSize = terminalTextSizeStore.points
            let cell = TerminalCellMetrics.cell(fontSize: fontSize, scale: scale)
            // The canvas's own window origin: a box snapped as if the canvas
            // began at the window's corner would still leave the surface on a
            // fractional device pixel.
            let grid = CanvasGrid(canvas: proxy.size, phase: proxy.frame(in: .global).origin, displayScale: scale)
            let geometry = resolvedGeometry(grid: grid)
            ZStack(alignment: .topLeading) {
                if let layout {
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
                                // herdr's zoom holds one pane of the tab
                                // open; the canvas still draws them all, so
                                // the badge is what says so. Read from
                                // `focusedPaneID`, never `focusedPane`: that
                                // one falls back to the first pane when the
                                // snapshot names none, which is a
                                // mutation-target rule and would paint the
                                // badge on an arbitrary pane here.
                                isZoomed: layout.zoomed && layout.focusedPaneID == pane.paneID,
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
                        .font(ChromeType.emptyCanvas)
                        .foregroundStyle(theme.textLabel)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                DropzoneOverlay(
                    theme: theme, layout: layout, exported: layout.flatMap { viewModel.exportedLayout(for: $0.tabID) },
                    grid: grid, dividerThickness: Self.dividerThickness
                )
                if layout != nil {
                    ForEach(geometry.dividers, id: \.path) { divider in
                        let band = divider.hitBand(thickness: DividerBand.thickness)
                        DividerHandleView(theme: theme, divider: divider, band: band)
                            .offset(x: band.minX, y: band.minY)
                    }
                    // On top of every divider: a T or a plus overlaps two
                    // bands in one square, which neither divider's own view
                    // can resolve alone (see `DividerIntersectionView`).
                    ForEach(DividerIntersections.find(in: geometry.dividers, bandThickness: DividerBand.thickness), id: \.id) { intersection in
                        DividerIntersectionView(intersection: intersection)
                            .offset(x: intersection.square.minX, y: intersection.square.minY)
                    }
                }
            }
            // Named so a divider gesture can read its pointer in the space
            // `geometry`'s own rects are stated in, rather than reconstruct
            // it from the moving band it is dragging.
            .coordinateSpace(.named(DragSpace.canvasContent))
            // The canvas lays out in its own space and drop hit-testing works
            // in the window's, so the frames are published translated by the
            // canvas's own origin there, once, here.
            .background { canvasReporter(geometry.offset(by: proxy.frame(in: DragSpace.coordinateSpace).origin)) }
        }
        .padding(Self.canvasPadding)
        .background(theme.canvas)
    }

    private func resolvedGeometry(grid: CanvasGrid) -> CanvasGeometry {
        guard let layout else { return .empty }
        let override = dividerDrag.liveOverride.flatMap { $0.tabID == layout.tabID ? (path: $0.path, ratio: $0.ratio) : nil }
        return CanvasGeometry.resolved(
            layout: layout,
            exported: viewModel.exportedLayout(for: layout.tabID),
            grid: grid,
            dividerThickness: Self.dividerThickness,
            liveRatioOverride: override
        )
    }

    private func canvasReporter(_ placed: CanvasGeometry) -> some View {
        Color.clear
            .onAppear { drag.canvas = placed }
            .onChange(of: placed) { _, new in drag.canvas = new }
    }

    /// What is left of a box for the terminal itself, once its chrome is
    /// taken out.
    private static func innerSize(of box: CGSize) -> CGSize {
        let chrome = PaneCellView.chrome
        return CGSize(width: max(0, box.width - chrome.width), height: max(0, box.height - chrome.height))
    }
}
