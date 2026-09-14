import PaddockCore
import SwiftUI

/// The pane canvas for the selected tab: herdr's cell grid (the tab's
/// `area`) rendered at ONE uniform cell size and letterboxed in the canvas,
/// so every pane box is exactly its herdr cell rect scaled and every
/// surface behind a box is exactly that pane's cols x rows at the fitted
/// font. `UniformCellLayout.fit` picks the font: the Terminal Text setting
/// is the maximum, shrunk only when the window cannot hold the grid at it.
/// `CanvasGeometry.resolved` then reads herdr's own `layout.export` split
/// tree when the view-model has one cached for this tab, falling back to
/// rect derivation otherwise; each pane renders inset by half the 6px gutter
/// so adjacent cells read as separated.
struct PaneCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?

    @Environment(TerminalTextSizeStore.self) private var terminalTextSizeStore
    @Environment(\.displayScale) private var displayScale
    /// The font size actually pushed to the surfaces: follows the fit after
    /// a short quiet period so a live window drag re-fonts every pane once,
    /// together, rather than on every frame. The first fit applies at once.
    @State private var appliedFontSize: Double?

    private static let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let fit: UniformCellFit? = layout.map { (snapshot: LayoutSnapshot) in fitGrid(of: snapshot, in: proxy.size) }
            ZStack(alignment: .topLeading) {
                if let layout, let fit {
                    let geometry = CanvasGeometry.resolved(
                        layout: layout,
                        exported: viewModel.exportedLayout(for: layout.tabID),
                        grid: fit.grid,
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
                                // placement, not the dims contract).
                                cols: paneRect.rect.width,
                                rows: paneRect.rect.height,
                                surfaceSize: fit.surfaceSize(cols: paneRect.rect.width, rows: paneRect.rect.height),
                                fontSizePoints: appliedFontSize ?? fit.fontSize
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
            .task(id: fit?.fontSize) {
                if let fontSize = fit?.fontSize { await applyFontSize(fontSize) }
            }
        }
        .padding(10)
        .background(theme.windowBg)
    }

    private func fitGrid(of layout: LayoutSnapshot, in canvas: CGSize) -> UniformCellFit {
        let scale = displayScale > 0 ? displayScale : 2
        return UniformCellLayout.fit(
            area: layout.area,
            panes: layout.panes.map(\.rect),
            canvas: canvas,
            chrome: PaneCellView.chrome(dividerThickness: Self.dividerThickness),
            maxFontSize: Double(terminalTextSizeStore.active.points),
            cellMetrics: { TerminalCellMetrics.cell(fontSize: $0, scale: scale) }
        )
    }

    /// Debounced by SwiftUI's own `.task(id:)` cancellation: a newer fit
    /// cancels the sleep, so only the last of a burst is applied.
    private func applyFontSize(_ fontSize: Double) async {
        if appliedFontSize != nil {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        appliedFontSize = fontSize
        terminalTextSizeStore.recordFit(fontSize)
    }
}
