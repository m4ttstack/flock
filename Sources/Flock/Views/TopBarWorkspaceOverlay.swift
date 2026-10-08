import FlockCore
import SwiftUI

/// A top-bar workspace on screen, in the shared modal. Keys go to the
/// focused pane; Esc is the program's, so closing is the modal's close, its
/// backdrop, or the icon again.
struct TopBarWorkspaceOverlay: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(TopBarOverlaySizeStore.self) private var sizes
    @Environment(TerminalTextSizeStore.self) private var textSize

    var body: some View {
        if let id = viewModel.topBarOverlay.openPin, let pin = viewModel.pins.pin(id) {
            ChromeModal(
                theme: theme, size: sizes.size(for: id),
                onSize: { sizes.select($0, for: id) }, onDismiss: { viewModel.topBarOverlay.close() }
            ) {
                TopBarOverlayTitle(theme: theme, pin: pin, tabCount: tabCount(of: pin))
            } content: { area, scale in
                TopBarOverlayCanvas(
                    theme: theme, viewModel: viewModel, layout: layout(of: pin), area: area, scale: scale,
                    fontSize: textSize.points
                )
                // Another pin's panes start from its own focus, not the last one's.
                .id(id)
            }
        }
    }

    private func layout(of pin: PinnedWorkspace) -> LayoutSnapshot? {
        guard let workspace = pin.workspace, let model = viewModel.userModel,
              let record = model.workspaces.first(where: { $0.workspaceID == workspace }) else { return nil }
        return model.layouts[record.activeTabID]
    }

    private func tabCount(of pin: PinnedWorkspace) -> Int {
        pin.workspace.flatMap { viewModel.userModel?.tabs[$0]?.count } ?? 1
    }
}

/// The modal title row's leading part: symbol, name, and a note while the
/// workspace has grown past one tab.
private struct TopBarOverlayTitle: View {
    let theme: Theme
    let pin: PinnedWorkspace
    let tabCount: Int

    var body: some View {
        HStack(spacing: ChromeMetrics.Modal.TitleRow.gap) {
            WorkspaceMark(theme: theme, key: pin.identityKey, size: ChromeMetrics.WorkspaceRow.mark)
            Text(pin.name)
                .font(ChromeType.modalTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .accessibilityIdentifier("flock.topBar.overlay.title")
            if tabCount > 1 {
                Text("\(tabCount) tabs: only the active one shows here")
                    .font(ChromeType.modalNote)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// The tab's panes where herdr's layout puts them, one `ModalTerminalPane`
/// each. Focus is local: nothing is sent to herdr, so its focus and the main
/// view's selection stay where they are.
struct TopBarOverlayCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?
    let area: CGSize
    let scale: CGFloat
    let fontSize: Double

    @State private var focused: PaneID?

    private static let gutter = DividerBand.gutter
    /// Whole points, so the surface inside an outline stays on device pixels.
    static let outlineInset = ChromeMetrics.selectionOutlineWidth.rounded(.up)

    var body: some View {
        if let layout {
            let geometry = Self.geometry(layout: layout, exported: viewModel.exportedLayout(for: layout.tabID), area: area, scale: scale)
            let cell = TerminalCellMetrics.cell(fontSize: fontSize, scale: scale)
            let focus = focusedPane(in: layout)
            // The terminal's ground is the card's, so only an outline can
            // tell one pane of a split from the next, and say which has the keys.
            let outlined = geometry.count > 1
            let inset = outlined ? Self.outlineInset : 0
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneID) { rect in
                    if let box = geometry[rect.paneID] {
                        let inner = box.insetBy(dx: inset, dy: inset)
                        let fit = SurfaceGrid.fit(inner: inner.size, cell: cell)
                        let isFocused = focus == rect.paneID
                        ModalTerminalPane(
                            theme: theme, viewModel: viewModel, paneID: rect.paneID,
                            grid: PTYSize(cols: fit.cols, rows: fit.rows), surfaceSize: fit.size,
                            fontSizePoints: fontSize, isFocused: isFocused,
                            command: nil, onFocus: { focused = rect.paneID }
                        )
                        .id(rect.paneID)
                        .frame(width: inner.width, height: inner.height, alignment: .topLeading)
                        .padding(inset)
                        .overlay {
                            if outlined {
                                RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).strokeBorder(
                                    isFocused ? theme.accent : theme.paneBorder,
                                    lineWidth: isFocused ? ChromeMetrics.selectionOutlineWidth : ChromeMetrics.ruleWidth
                                )
                            }
                        }
                        .offset(x: box.minX, y: box.minY)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("flock.topBar.overlay.pane.\(rect.paneID.rawValue)")
                    }
                }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
        } else {
            PaneLoaderView(theme: theme)
        }
    }

    /// The pane clicked last while it is still in the tab, else herdr's
    /// focused pane in the tab, else its first.
    private func focusedPane(in layout: LayoutSnapshot) -> PaneID? {
        let panes = layout.panes.map(\.paneID)
        if let focused, panes.contains(focused) { return focused }
        if let herdr = layout.focusedPaneID, panes.contains(herdr) { return herdr }
        return layout.panes.first { $0.focused }?.paneID ?? panes.first
    }

    /// Each pane's box in `area`. Laid out over `area` grown by one gutter so
    /// that `PaneBox`'s half-gutter insets fall outside it on the outer edges:
    /// the outer boxes meet the modal's own inset as the rt modal's one pane
    /// does, and adjacent boxes still leave one gutter between them.
    static func geometry(
        layout: LayoutSnapshot, exported: ExportedLayoutDescription?, area: CGSize, scale: CGFloat
    ) -> [PaneID: CGRect] {
        let grid = CanvasGrid(
            canvas: CGSize(width: area.width + gutter, height: area.height + gutter), phase: .zero, displayScale: scale
        )
        let resolved = CanvasGeometry.resolved(
            layout: layout, exported: exported, grid: grid, dividerThickness: gutter,
            liveRatioOverride: nil, composition: .of(layout: layout)
        )
        let shift = PaneBox.leadingInset(dividerThickness: gutter)
        return resolved.paneFrames.mapValues { PaneBox.frame(in: $0, dividerThickness: gutter).offsetBy(dx: -shift, dy: -shift) }
    }
}
