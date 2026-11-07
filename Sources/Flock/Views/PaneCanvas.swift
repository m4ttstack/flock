import FlockCore
import SwiftUI

/// The pane canvas for the selected tab: herdr's split geometry read as
/// PROPORTIONS of the tab's cell area and stretched to fill the window, so
/// the canvas is always full and flock's own boxes decide how big each pane
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
    /// Shows only this pane, over the whole canvas, in a view that is never a
    /// drop target and never moves herdr's focus.
    var solo: PaneID? = nil

    @Environment(TerminalTextSizeStore.self) private var terminalTextSizeStore
    @Environment(DragCoordinator.self) private var drag
    @Environment(DividerDragCoordinator.self) private var dividerDrag
    @Environment(\.displayScale) private var displayScale
    @Environment(PaneAppearanceStore.self) private var appearance: PaneAppearanceStore?
    /// The window is being dragged by an edge right now. Every cell freezes
    /// its surface for the whole gesture, the same way a divider drag does:
    /// this arrives once per gesture, where `proxy.size` arrives once per
    /// intermediate frame and so can never tell a resize from its end.
    @State private var isWindowResizing = false

    private var isEdgeToEdge: Bool { (appearance?.layout ?? .standard) == .edgeToEdge }

    private var dividerThickness: CGFloat {
        isEdgeToEdge ? ChromeMetrics.Pane.EdgeToEdge.gutter : DividerBand.gutter
    }

    private var bandThickness: CGFloat {
        isEdgeToEdge ? ChromeMetrics.Pane.EdgeToEdge.bandThickness : DividerBand.thickness
    }

    private var canvasPadding: EdgeInsets {
        let padding = PaneBox.canvasPadding(margin: isEdgeToEdge ? 0 : ChromeMetrics.Canvas.margin, dividerThickness: dividerThickness)
        return EdgeInsets(
            top: padding.leadingAndTop, leading: padding.leadingAndTop,
            bottom: padding.trailingAndBottom, trailing: padding.trailingAndBottom
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = displayScale > 0 ? displayScale : 2
            let fontSize = terminalTextSizeStore.points
            let cell = TerminalCellMetrics.cell(fontSize: fontSize, scale: scale)
            // The canvas's own window origin: a box snapped as if the canvas
            // began at the window's corner would still leave the surface on a
            // fractional device pixel.
            let grid = CanvasGrid(canvas: proxy.size, phase: proxy.frame(in: .global).origin, displayScale: scale)
            let composition = solo.map { CanvasComposition.zoomed($0) } ?? layout.map { CanvasComposition.of(layout: $0) } ?? .tiled
            let geometry = resolvedGeometry(grid: grid, composition: composition)
            let compact: Set<PaneID> = compactPanes(in: geometry)
            ZStack(alignment: .topLeading) {
                if let layout {
                    ForEach(layout.panes, id: \.paneID) { paneRect in
                        if let pane = viewModel.model?.panes[paneRect.paneID],
                           let frame = geometry.paneFrames[paneRect.paneID] {
                            let box = PaneBox.frame(in: frame, dividerThickness: dividerThickness)
                            paneCell(
                                pane, box: box, isCompact: compact.contains(pane.paneID),
                                isZoomed: solo == nil && composition.zoomedPaneID == pane.paneID, cell: cell, fontSize: fontSize
                            )
                        }
                    }
                } else {
                    Text("No tab selected")
                        .font(ChromeType.emptyCanvas)
                        .foregroundStyle(theme.textLabel)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                if solo == nil {
                    DropzoneOverlay(
                        theme: theme, layout: layout, exported: layout.flatMap { viewModel.exportedLayout(for: $0.tabID) },
                        grid: grid, dividerThickness: dividerThickness
                    )
                }
                if layout != nil, solo == nil {
                    ForEach(geometry.dividers, id: \.path) { divider in
                        let band = divider.hitBand(thickness: bandThickness)
                        DividerHandleView(theme: theme, divider: divider, band: band)
                            .offset(x: band.minX, y: band.minY)
                    }
                    // On top of every divider: a T or a plus overlaps two
                    // bands in one square, which neither divider's own view
                    // can resolve alone (see `DividerIntersectionView`).
                    ForEach(DividerIntersections.find(in: geometry.dividers, bandThickness: bandThickness), id: \.id) { intersection in
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
            .background {
                if solo == nil {
                    canvasReporter(geometry.offset(by: proxy.frame(in: DragSpace.coordinateSpace).origin))
                }
            }
            .background { WindowLiveResizeReporter { isWindowResizing = $0 } }
            .environment(\.paneStatusSpan, proxy.frame(in: DragSpace.coordinateSpace))
        }
        .padding(canvasPadding)
        // Edge to edge, the one point between panes is all of the canvas
        // that shows, so its colour is the divider's.
        .background(isEdgeToEdge ? theme.hair : theme.canvas)
    }

    private func resolvedGeometry(grid: CanvasGrid, composition: CanvasComposition) -> CanvasGeometry {
        guard let layout else { return .empty }
        let override = dividerDrag.liveOverride.flatMap { $0.tabID == layout.tabID ? (path: $0.path, ratio: $0.ratio) : nil }
        return CanvasGeometry.resolved(
            layout: layout,
            exported: viewModel.exportedLayout(for: layout.tabID),
            grid: grid,
            dividerThickness: dividerThickness,
            liveRatioOverride: override,
            composition: composition
        )
    }

    private func canvasReporter(_ placed: CanvasGeometry) -> some View {
        Color.clear
            .onAppear { drag.canvas = placed }
            .onChange(of: placed) { _, new in drag.canvas = new }
    }

    /// What is left of a box for the terminal itself, once its chrome is
    /// taken out.
    @ViewBuilder
    private func paneCell(
        _ pane: PaneRecord, box: CGRect, isCompact: Bool, isZoomed: Bool, cell: CGSize, fontSize: Double
    ) -> some View {
        let fit = SurfaceGrid.fit(
            inner: Self.innerSize(
                of: box.size, flush: PaneChrome.isFlush(agent: pane.agent), compact: isCompact
            ), cell: cell
        )
        PaneCellView(
            theme: theme,
            viewModel: viewModel,
            pane: pane,
            // The canvas's own focus, which the rt modal
            // drawn over it withholds so its surface
            // keeps the keyboard. Otherwise it is the
            // solo pane or the view-model's resolved
            // focus, not
            // `layout.focusedPaneID` (a `pane.focus` jump
            // never touches the layout snapshot, only
            // `model.focusedPaneID`) and not
            // `model.focusedPaneID` directly (that only
            // updates once herdr's echo lands, tens of ms
            // after the click -- `resolvedFocusedPaneID`
            // paints the optimistic prediction instead).
            isFocused: pane.paneID == viewModel.canvasFocus(solo: solo),
            // The same answer the geometry above was
            // built from, so the badge can only ever ride
            // the pane that is actually filling the
            // canvas.
            isZoomed: isZoomed,
            lastLine: viewModel.lastLine(for: pane),
            grid: PTYSize(cols: fit.cols, rows: fit.rows),
            surfaceSize: fit.size,
            fontSizePoints: fontSize,
            windowIsResizing: isWindowResizing,
            compactHeader: isCompact
        )
        .environment(\.paneCellRole, solo == nil ? .canvas : .solo)
        // Placed by offset rather than `.position`, which
        // centers on a midpoint and so halves the box size:
        // this keeps the snapped origin exactly as
        // `CanvasGrid` produced it.
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .offset(x: box.minX, y: box.minY)
        // A container, so the identifier below names the
        // whole box. Without it SwiftUI folds the cell into
        // the one text inside it and the identifier comes
        // back as the title's own frame: a few dozen points
        // in the corner of a pane hundreds wide, which is
        // the wrong place for everything that reads a
        // cell's geometry.
        //
        // `.contain` rather than `.combine`: the title and
        // the window control inside carry identifiers of their
        // own, and combining would swallow both. The
        // container is left unnamed for now; a label on it
        // is a reader's improvement, but it is also the
        // one thing that could fold the children back in,
        // and their being separately addressable is what
        // the window control is read through.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.canvas.pane.\(pane.paneID.rawValue)")
    }

    private func compactPanes(in geometry: CanvasGeometry) -> Set<PaneID> {
        PaneChrome.compactPanes(geometry.paneFrames.map { id, frame in
            (id: id, agent: viewModel.model?.panes[id]?.agent, top: frame.minY)
        })
    }

    private static func innerSize(of box: CGSize, flush: Bool, compact: Bool) -> CGSize {
        let chrome = PaneChrome.size(flush: flush, compact: compact)
        return CGSize(width: max(0, box.width - chrome.width), height: max(0, box.height - chrome.height))
    }
}
