import AppKit
import FlockCore
import SwiftUI

/// Every workspace at once, one island each, its tabs drawn as their split
/// layouts in miniature. It stands in for the rail, strip and canvas while
/// shown. Thumbnails come from the layout snapshots and cached exports only:
/// the grid never attaches a pane, since attaching sizes the real one.
struct AllWorkspacesGrid: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode
    @Environment(WorkspaceIdentityStore.self) private var identity
    @Environment(BoardStore.self) private var boardNames
    @Environment(HerdProgressStore.self) private var herdProgress
    @State private var scrollPosition = ScrollPosition()
    /// The fit on screen. Written only while no drag is live, so the fit a
    /// drag starts with is the one it keeps (`IslandFitHold`).
    @State private var hold = IslandFitHold()
    /// The space the islands can use: the scroll view less the canvas
    /// padding on each side.
    @State private var viewport: CGSize = .zero
    /// The zoomed island's fit, held through a drag like the grid's.
    @State private var zoomHold = IslandFitHold()
    /// The zoomed island's place in the grid, in the scroll view's space.
    @State private var zoomSource: CGRect?
    /// The workspace the last zoom was into, kept until a zoom out has
    /// finished shrinking back over its grid island.
    @State private var zoomReturning: WorkspaceID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrangeZoomPreviewProgress) private var zoomPreviewProgress

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        // Built once per pass and only for Arrange: it reads the board, the
        // rail sections and the fit, and a drag re-runs this at pointer rate.
        let arrange = shownMode == .arrange ? self.arrange : nil
        // Mission control is never a drop target, so it publishes no items.
        let order = arrange.map { itemOrder($0.fit) } ?? []
        let zoomedOrder = arrange?.zoomFit.map(itemOrder) ?? []
        VStack(spacing: 0) {
            if arrange == nil, let focused = drag.gridFocusedPane {
                FocusedPaneView(theme: theme, viewModel: viewModel, pane: focused)
            } else {
                header
                Rectangle()
                    .fill(theme.rule)
                    .frame(height: ChromeMetrics.ruleWidth)
                if let arrange {
                    arrangeGrid(arrange)
                } else {
                    MissionControlView(theme: theme, viewModel: viewModel)
                }
            }
        }
        .boundedBackground(theme.chrome)
        .onAppear {
            mode.opened(dragInFlight: drag.activeSubject != nil)
            refreshIdentities()
            drag.setGridOrder(order)
            drag.setGridOrder(zoomedOrder, layer: .zoomed)
        }
        .onChange(of: order) { drag.setGridOrder(order) }
        .onChange(of: zoomedOrder) { drag.setGridOrder(zoomedOrder, layer: .zoomed) }
        .onChange(of: workspaces.map(\.workspaceID)) { _, ids in
            refreshIdentities()
            if let zoomed = drag.gridZoomed, !ids.contains(zoomed) { drag.unzoomGrid() }
        }
        // A zoom belongs to this visit to Arrange.
        .onChange(of: shownMode) { _, shown in
            if shown != .arrange { drag.unzoomGrid() }
        }
        // Initial too: a remembered focused pane may have closed while the
        // view was away.
        .onChange(of: livePanes, initial: true) { _, live in
            // A nil model is a gap in the connection, not every pane closing.
            guard let live else { return }
            drag.updateGrid { $0.reconcile(livePanes: live) }
        }
    }

    private var livePanes: Set<PaneID>? { viewModel.model.map { Set($0.panes.keys) } }

    private var shownMode: AllWorkspacesMode { mode.shown(dragInFlight: drag.activeSubject != nil) }

    private func arrangeGrid(_ arrange: Arrangement) -> some View {
        ScrollView(.vertical) {
            canvas(arrange)
                .reportsDragFrame { drag.setGridContentOrigin($0.origin) }
                .padding(ChromeMetrics.Grid.canvasPadding)
                // A minimum of zero, or the rows laid out for the last viewport
                // hold the scroll view (and so the measured viewport) at least
                // that wide, and narrowing the window never refits.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(
                width: max(0, proxy.size.width - 2 * ChromeMetrics.Grid.canvasPadding),
                height: max(0, proxy.size.height - 2 * ChromeMetrics.Grid.canvasPadding)
            )
        } action: { viewport = $0 }
        .onChange(of: arrange.inputs, initial: true) { holdFit(arrange.inputs) }
        .onChange(of: drag.activeSubject == nil) { _, idle in
            guard idle else { return }
            holdFit(self.arrange.inputs)
        }
        .background { ArrangeKeyMonitor(space: spacePressed, open: openSelection) }
        .task(id: arrange.zoomed) {
            if let zoomed = arrange.zoomed {
                zoomReturning = zoomed
                return
            }
            try? await Task.sleep(for: .seconds(ArrangeZoomMotion.duration(reduceMotion: reduceMotion)))
            guard !Task.isCancelled else { return }
            zoomReturning = nil
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollPosition($scrollPosition)
        .reportsScrollExtent(.vertical) { drag.setGridScroll(offset: $0, maximumOffset: $1) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .boundedBackground(theme.canvas)
        // A click anywhere a thumbnail does not claim puts the selection
        // down.
        .contentShape(Rectangle())
        .onTapGesture { drag.deselectGridPane() }
        .reportsDragFrame { drag.gridViewport = $0 }
        .onAppear { drag.gridScroller = { y in scrollPosition.scrollTo(y: y) } }
    }

    /// Every island, with the zoomed one in front of them while there is
    /// one. The grid stays built behind a zoom, and nothing it is handed
    /// changes when a zoom starts or ends, so zooming out brings back islands
    /// that are already laid out rather than building them all in the frame
    /// the key or click waits on. Behind, it takes no clicks, its tiles read
    /// nothing (`ArrangeTileBody`), and its frames are kept apart from the
    /// zoomed island's (`ArrangeLayer`), so a drop reads the zoomed island's
    /// alone.
    ///
    /// Each layer is its own content space, named INSIDE the transform that
    /// carries it: a frame measured against it never sees the zoom's scale
    /// or offset, so the transition moves drawn layers and writes no item
    /// frames while it runs, and the content origin is the stack's, which
    /// nothing transforms.
    @ViewBuilder
    private func canvas(_ arrange: Arrangement) -> some View {
        let zoomed = arrange.zoomed.flatMap { id in workspaces.first { $0.workspaceID == id } }
        let isZoomed = zoomed != nil && arrange.zoomFit != nil
        let preview = isZoomed ? zoomPreviewProgress : nil
        ArrangeCanvasLayout(isZoomed: isZoomed) {
            islandRows(arrange)
                .coordinateSpace(.named(DragSpace.gridContent))
                .modifier(ArrangeRecede(progress: preview ?? (isZoomed ? 1 : 0), travels: !reduceMotion))
                .allowsHitTesting(!isZoomed)
                .accessibilityHidden(isZoomed)
            if let zoomed, let zoomFit = arrange.zoomFit {
                if let preview {
                    zoomedIsland(zoomed, fit: zoomFit, arrange: arrange)
                        .coordinateSpace(.named(DragSpace.gridContent))
                        .modifier(ArrangeZoomFrame(source: zoomSource ?? zoomTarget, target: zoomTarget, progress: preview))
                } else {
                    zoomedIsland(zoomed, fit: zoomFit, arrange: arrange)
                        .arrangeZoomStill(reduceMotion: reduceMotion)
                        .coordinateSpace(.named(DragSpace.gridContent))
                        .transition(ArrangeZoomMotion.zoomed(from: zoomSource, to: zoomTarget, reduceMotion: reduceMotion))
                }
            }
        }
        .animation(ArrangeZoomMotion.animation(reduceMotion: reduceMotion), value: arrange.zoomed)
    }

    private func islandRows(_ arrange: Arrangement) -> some View {
        let fit = arrange.fit
        let metrics = ChromeMetrics.Grid.islands
        return VStack(alignment: .leading, spacing: metrics.islandGap) {
            ForEach(fit.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: metrics.islandGap) {
                    ForEach(row, id: \.self) { id in
                        if let workspace = workspaces.first(where: { $0.workspaceID == id }) {
                            WorkspaceIsland(
                                theme: theme, viewModel: viewModel, workspace: workspace,
                                slotsPerRow: fit.tabsPerRow[id] ?? 1,
                                identityKey: arrange.sections.flatMap { WorkspaceIdentityStore.key(for: id, sections: $0) },
                                zoom: IslandZoom(isZoomed: false) { zoom(into: id) }
                            )
                            // Under the zoomed island while it grows out of
                            // this place and shrinks back into it: the
                            // zoom's scale draws its corners smaller than
                            // these, so both showing reads as two outlines.
                            .opacity(id == (arrange.zoomed ?? zoomReturning) ? 0 : 1)
                        }
                    }
                }
                // Islands sharing a row share the taller one's height.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.gridThumbnailSize, CGSize(width: fit.thumbnailWidth, height: fit.thumbnailHeight))
        .environment(\.arrangeTiles, ArrangeTileContext(interval: TileTailCadence.grid))
    }

    private func zoomedIsland(_ workspace: WorkspaceRecord, fit: IslandLayout.Fit, arrange: Arrangement) -> some View {
        let id = workspace.workspaceID
        return WorkspaceIsland(
            theme: theme, viewModel: viewModel, workspace: workspace,
            slotsPerRow: fit.tabsPerRow[id] ?? 1,
            identityKey: arrange.sections.flatMap { WorkspaceIdentityStore.key(for: id, sections: $0) },
            zoom: IslandZoom(isZoomed: true) { drag.unzoomGrid() }
        )
        .environment(\.gridThumbnailSize, CGSize(width: fit.thumbnailWidth, height: fit.thumbnailHeight))
        .environment(\.arrangeTiles, ArrangeTileContext(interval: TileTailCadence.zoomed, isZoomed: true))
    }

    /// The zoomed island's place: the whole canvas inside its padding, in the
    /// scroll view's own space, which a zoom scrolls back to the top of.
    private var zoomTarget: CGRect {
        CGRect(origin: CGPoint(x: ChromeMetrics.Grid.canvasPadding, y: ChromeMetrics.Grid.canvasPadding), size: viewport)
    }

    /// Where the island is in the grid, read once as the zoom starts: the
    /// zoom grows out of it and shrinks back into it.
    private func zoom(into id: WorkspaceID) {
        guard drag.activeSubject == nil else { return }
        if let card = drag.gridItemFrame(for: .card(id)), let scroller = drag.gridViewport {
            zoomSource = card.offsetBy(dx: -scroller.minX, dy: -scroller.minY)
        }
        // Read before the island grows, so its tiles open on output rather
        // than filling in as the zoom lands.
        let panes = viewModel.model?.panes.values.filter { $0.workspaceID == id } ?? []
        for pane in panes where viewModel.paneTails[pane.paneID] == nil {
            viewModel.refreshPaneTail(for: pane.paneID)
        }
        drag.deselectGridPane()
        scrollPosition.scrollTo(y: 0)
        drag.zoomGrid(into: id)
    }

    /// Space zooms into the current workspace, the outlined island, and
    /// back out. Never while a name is being typed or a drag is live.
    private func spacePressed() -> Bool {
        guard drag.activeSubject == nil, viewModel.renameTarget == nil else { return false }
        if drag.gridZoomed != nil {
            drag.unzoomGrid()
            return true
        }
        guard let id = viewModel.model?.focusedWorkspaceID, workspaces.contains(where: { $0.workspaceID == id }) else { return false }
        zoom(into: id)
        return true
    }

    /// Return opens the selected mini pane in Workspaces. Never while a name
    /// is being typed, whose Return commits it, or while a drag is live.
    private func openSelection() -> Bool {
        guard drag.activeSubject == nil, viewModel.renameTarget == nil,
              let pane = drag.gridSelection, let tab = viewModel.model?.panes[pane]?.tabID
        else { return false }
        ArrangeOpen.open(tab: tab, pane: pane, viewModel: viewModel, drag: drag)
        return true
    }

    private var header: some View {
        HStack(spacing: ChromeMetrics.Grid.headerSpacing) {
            Text(workspaces.count == 1 ? "1 workspace" : "\(workspaces.count) workspaces")
                .font(ChromeType.gridCount)
                .foregroundStyle(theme.textLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ChromeMetrics.Grid.headerHorizontalPadding)
        .frame(height: ChromeMetrics.Grid.headerHeight)
        .background(WindowDragExclusion())
    }

    private func refreshIdentities() {
        guard viewModel.model?.workspaces.isEmpty == false,
              let sections = viewModel.railSections(board: boardNames.names, herdProgress: herdProgress.progress)
        else { return }
        identity.refresh(sections)
    }

    /// What Arrange draws: every workspace's island as the fit lays it out.
    private struct Arrangement {
        struct Inputs: Equatable {
            let islands: [IslandLayout.Island]
            let viewport: CGSize
            let zoomed: WorkspaceID?
        }

        let sections: RailSections?
        let inputs: Inputs
        let fit: IslandLayout.Fit
        /// Set only while that workspace is still there to draw.
        let zoomed: WorkspaceID?
        let zoomFit: IslandLayout.Fit?
    }

    private var arrange: Arrangement {
        let model = viewModel.model
        let sections = viewModel.railSections(board: boardNames.names, herdProgress: herdProgress.progress)
        let ranked = sections?.railOrder ?? []
        let ordered = ranked.compactMap { id in workspaces.first { $0.workspaceID == id } }
            + workspaces.filter { !ranked.contains($0.workspaceID) }
        let islands = ordered.map {
            IslandLayout.Island(id: $0.workspaceID, tabs: model?.tabs[$0.workspaceID]?.count ?? 1)
        }
        let zoomed = drag.gridZoomed.flatMap { id in islands.first { $0.id == id } }
        let inputs = Arrangement.Inputs(islands: islands, viewport: viewport, zoomed: zoomed?.id)
        let dragging = drag.activeSubject != nil
        // Copies, so `body` never writes state; `holdFit` keeps the stored ones.
        var held = hold
        let fit = held.update(islands, in: viewport, dragging: dragging, metrics: ChromeMetrics.Grid.islands)
        var heldZoom = zoomHold
        let zoomFit = zoomed.map { heldZoom.update(zoomed: $0, in: viewport, dragging: dragging, metrics: ChromeMetrics.Grid.islands) }
        return Arrangement(sections: sections, inputs: inputs, fit: fit, zoomed: zoomed?.id, zoomFit: zoomFit)
    }

    private func holdFit(_ inputs: Arrangement.Inputs) {
        guard drag.activeSubject == nil else { return }
        _ = hold.update(inputs.islands, in: inputs.viewport, dragging: false, metrics: ChromeMetrics.Grid.islands)
        if let zoomed = inputs.zoomed, let island = inputs.islands.first(where: { $0.id == zoomed }) {
            _ = zoomHold.update(zoomed: island, in: inputs.viewport, dragging: false, metrics: ChromeMetrics.Grid.islands)
        }
    }

    /// The items a drop can hit, in grid order: what turns their frames back
    /// into a list and drops the frame of an item no longer shown. `.newTab`
    /// names the rect the created tab lands in, whichever cell is drawing it.
    private func itemOrder(_ fit: IslandLayout.Fit) -> [GridItemID] {
        let drawn = fit.rows.joined().filter { id in workspaces.contains { $0.workspaceID == id } }
        return drawn.flatMap { id -> [GridItemID] in
            let tabs = (viewModel.model?.tabs[id] ?? []).map(\.tabID)
            let preview = CardDropPreview(workspace: id, drag: drag, model: viewModel.model)
            let cells = preview.cells(of: tabs, perRow: fit.tabsPerRow[id] ?? 1)
            // The created tab's id is published once, wherever its slot turns
            // out to be: the card hangs the reporter on that cell rather than
            // on the placeholder, which is drawn somewhere else whenever the
            // drop also empties one of this card's tabs.
            return [.card(id)]
                + (preview.takesTheDrop ? [.newTab(id)] : [])
                + cells.compactMap { cell -> GridItemID? in
                    switch cell {
                    case .tab(let tab): .tab(tab)
                    case .newTab: nil
                    }
                }
        }
    }
}

/// What one card previews while a drag is live. Decided once and read by both
/// the card and the grid's item order, so the two cannot disagree about
/// whether a cell is standing in for a tab.
@MainActor
private struct CardDropPreview {
    /// The card is the resolved target AND the planner commits something, so
    /// the card is outlined and washed. Keyed on the plan rather than on the
    /// target alone: a tab dragged over its own workspace resolves to that
    /// card and plans nothing at all.
    let takesTheDrop: Bool
    /// A tab of THIS card the same drop takes away: the pane being dropped is
    /// the last one in it, so that tab is gone by the time the created one
    /// lands and the card lays the preview out without it.
    let closingTab: TabID?

    init(workspace: WorkspaceID, drag: DragCoordinator, model: SessionModel?) {
        let target = DropTarget.workspaceThumbnail(workspace)
        guard drag.target == target, let subject = drag.activeSubject, let model,
              case .success = plan(dragging: subject, onto: target, model: model)
        else {
            takesTheDrop = false
            closingTab = nil
            return
        }
        takesTheDrop = true
        closingTab = Self.tabEmptiedBy(subject, of: workspace, model: model)
    }

    /// The cells this card draws while the drop is previewed. Read by both the
    /// card and the grid's item order, so the two cannot disagree about which
    /// slot stands in for the created tab.
    func cells(of tabs: [TabID], perRow: Int) -> [GridCell] {
        GridCardLayout.cells(tabs: tabs, newTab: takesTheDrop, closing: closingTab, perRow: perRow)
    }

    /// The cell a committed drop actually lands in, as an index into the cells
    /// the card draws. Nil when this card takes no drop.
    func landingSlot(of tabs: [TabID]) -> Int? {
        guard takesTheDrop else { return nil }
        return GridCardLayout.landingSlot(tabs: tabs, closing: closingTab)
    }

    private static func tabEmptiedBy(_ subject: DragSubject, of workspace: WorkspaceID, model: SessionModel) -> TabID? {
        guard case .pane(let pane) = subject, let record = model.panes[pane],
              model.tabs[workspace]?.contains(where: { $0.tabID == record.tabID }) == true,
              model.panes.values.filter({ $0.tabID == record.tabID }).count == 1
        else {
            return nil
        }
        return record.tabID
    }
}

/// What one card previews while a tab is dragged among its own cells. Keyed on
/// the plan like every other grid preview: a drop that commits nothing slides
/// no cell and outlines no card, whether that is a tab dropped back in its own
/// gap or a tab the model has moved out of this workspace under the drag.
@MainActor
private struct CardReorderPreview {
    let takesTheDrop: Bool
    /// How far each of this card's thumbnails slides, empty unless the drop
    /// commits.
    let displacements: [TabID: CGSize]

    init(workspace: WorkspaceID, drag: DragCoordinator, model: SessionModel?) {
        guard let target = drag.target, case .tabStrip(let reordering, _) = target, reordering == workspace,
              let subject = drag.activeSubject, case .tab = subject,
              let model, case .success = plan(dragging: subject, onto: target, model: model)
        else {
            takesTheDrop = false
            displacements = [:]
            return
        }
        takesTheDrop = true
        displacements = drag.gridTabDisplacements(inCardFor: workspace)
    }
}

/// An island's way into a zoom, or out of the one it is in.
private struct IslandZoom {
    let isZoomed: Bool
    let toggle: () -> Void
}

private struct WorkspaceIsland: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let workspace: WorkspaceRecord
    /// The fit's slot count for this island, so the cells it draws and the
    /// ids the grid publishes for them are laid out against one count.
    let slotsPerRow: Int
    /// Nil for a herd, which takes no symbol of its own.
    let identityKey: String?
    let zoom: IslandZoom

    @Environment(DragCoordinator.self) private var drag
    @Environment(\.gridThumbnailSize) private var thumbnailSize
    @Environment(BoardStore.self) private var boardNames
    @Environment(WorkspaceIdentityStore.self) private var identityStore
    @State private var isPickingSymbol = false
    @State private var isHovering = false

    private var isFocusedWorkspace: Bool { workspace.workspaceID == viewModel.model?.focusedWorkspaceID }

    private var layer: ArrangeLayer { zoom.isZoomed ? .zoomed : .grid }

    var body: some View {
        let tabs = viewModel.model?.tabs[workspace.workspaceID] ?? []
        let rows = GridCardLayout.rows(preview.cells(of: tabs.map(\.tabID), perRow: slotsPerRow), perRow: slotsPerRow)
        // Read once per island rather than per cell: only the island a
        // reorder is over, and only while that reorder commits, has any.
        let displacements = reorder.displacements
        let metrics = ChromeMetrics.Grid.islands
        let shape = RoundedRectangle(cornerRadius: ChromeRadius.container)
        VStack(alignment: .leading, spacing: 0) {
            header(tabCount: tabs.count)
            VStack(alignment: .leading, spacing: ChromeMetrics.Grid.tabGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    // Every row keeps all its slots, so a short row's tabs are
                    // as wide as a full row's.
                    HStack(alignment: .top, spacing: ChromeMetrics.Grid.tabGap) {
                        // One width for every cell, so a thumbnail and the
                        // placeholder are always the same size and a row that
                        // does not fill its card leaves the slack at its own
                        // trailing edge.
                        //
                        // Keyed by the cell, never its column. A frame report
                        // fires only on appear and on a geometry change, so a
                        // tab that rewraps into the very slot another tab held
                        // (the first pass lays out at one per row, before the
                        // width is measured) would never report where it is.
                        ForEach(Array(row.enumerated()), id: \.element) { column, cell in
                            self.cell(
                                cell, at: rowIndex * slotsPerRow + column, tabs: tabs, displacements: displacements
                            )
                            .frame(width: thumbnailSize.width)
                        }
                    }
                }
            }
        }
        .padding(.top, ChromeMetrics.Grid.islandTopPadding)
        .padding(.bottom, metrics.bottomPadding)
        .padding(.horizontal, metrics.horizontalPadding)
        // The fit's own width, so a long name truncates rather than widening
        // the island past what the fit measured.
        .frame(
            width: IslandLayout.width(tabs: tabs.count, perRow: slotsPerRow, thumbnail: thumbnailSize.width, metrics: metrics),
            alignment: .leading
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .workspaceGround(theme, in: shape)
        .fadingHover($isHovering)
        .workspaceMenu(
            viewModel: viewModel, workspace: workspace.workspaceID, key: identityKey,
            changeSymbol: WorkspaceMark.drawsSymbol(key: identityKey, logo: boardNames.logo, in: identityStore)
                ? { isPickingSymbol = true } : nil
        )
        .overlay { DropWash(theme: theme, isTargeted: takesTheDrop, cornerRadius: ChromeRadius.container) }
        .overlay(shape.strokeBorder(outline(tabs), lineWidth: ChromeMetrics.selectionOutlineWidth))
        .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: isTargeted(tabs))
        .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .card(workspace.workspaceID), layer: layer) }
        // A container, not one combined element: an island really does hold
        // the tab thumbnails, each of which is its own tile. Undeclared,
        // SwiftUI folds the whole island into its text leaves and stamps this
        // identifier on every one of them, which both loses the island's own
        // box and overwrites the identifier each thumbnail carries.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.grid.workspace.\(workspace.workspaceID.rawValue)")
    }

    private func outline(_ tabs: [TabRecord]) -> Color {
        if isTargeted(tabs) { return theme.accent }
        return isFocusedWorkspace ? theme.textLabel : .clear
    }

    private func header(tabCount: Int) -> some View {
        HStack(spacing: ChromeMetrics.Grid.islandHeaderSpacing) {
            WorkspaceMark(theme: theme, key: identityKey, size: ChromeMetrics.Grid.workspaceMark, picking: $isPickingSymbol)
            if viewModel.renameTarget == .workspace(workspace.workspaceID) {
                InlineRenameField(
                    theme: theme, font: ChromeType.gridCardName,
                    initialText: viewModel.renameText(for: .workspace(workspace.workspaceID)),
                    accessibilityIdentifier: "flock.grid.rename.\(workspace.workspaceID.rawValue)",
                    onCommit: { text in
                        Task { await viewModel.commitRename(text, for: .workspace(workspace.workspaceID)) }
                    },
                    onCancel: { viewModel.cancelRename() }
                )
            } else {
                Text(workspace.label)
                    .font(ChromeType.gridCardName)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
            }
            StatusDot(shown: viewModel.shownStatus(of: workspace), theme: theme, size: ChromeMetrics.Grid.cardStatusDot + 2)
            Spacer(minLength: 0)
            Text(tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
                .font(ChromeType.gridCardMeta)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
                .fixedSize()
            // Held in the row while hidden, so hovering never moves the count.
            ArrangeZoomControl(theme: theme, isZoomed: zoom.isZoomed, workspace: workspace.workspaceID, action: zoom.toggle)
                .opacity(zoom.isZoomed || (isHovering && drag.activeSubject == nil) ? 1 : 0)
                .allowsHitTesting(zoom.isZoomed || isHovering)
        }
        .frame(height: ChromeMetrics.Grid.islandHeaderHeight)
        .padding(.bottom, ChromeMetrics.Grid.islandHeaderGap)
        .contentShape(Rectangle())
        // ONE tap gesture reading the click count: a `count: 2` tap here
        // would hold every click inside the header, the zoom control's
        // included, for the double-click interval (`ChromeRowClick`).
        .onTapGesture {
            guard NSEvent.isPrimaryDoubleClick(NSApp.currentEvent), drag.activeSubject == nil,
                  viewModel.renameTarget == nil
            else { return }
            zoom.toggle()
        }
    }

    /// One cell, plus the reporter for the slot a committed drop lands in
    /// when that slot is this one. The reporter is a view of its own rather
    /// than a second call inside the cell's: a frame report fires on appear
    /// and on a geometry change, and a cell's geometry is exactly what does
    /// NOT change when it becomes the drop's landing slot.
    private func cell(
        _ cell: GridCell, at index: Int, tabs: [TabRecord], displacements: [TabID: CGSize]
    ) -> some View {
        content(cell, tabs: tabs, displacements: displacements)
            .background {
                if index == landingSlot(tabs) {
                    Color.clear.reportsFrame(in: DragSpace.gridContent) {
                        drag.setGridItemFrame($0, for: .newTab(workspace.workspaceID), layer: layer)
                    }
                }
            }
    }

    /// Which of this card's cells a committed drop lands in, if any.
    private func landingSlot(_ tabs: [TabRecord]) -> Int? {
        preview.landingSlot(of: tabs.map(\.tabID))
    }

    @ViewBuilder
    private func content(_ cell: GridCell, tabs: [TabRecord], displacements: [TabID: CGSize]) -> some View {
        switch cell {
        case .tab(let id):
            if let tab = tabs.first(where: { $0.tabID == id }) {
                TabThumbnail(
                    theme: theme, viewModel: viewModel, tab: tab,
                    isTargeted: MiniPaneLayout.targetedTab(of: drag.target, dragging: drag.activeSubject, model: viewModel.model) == id,
                    displacement: displacements[id] ?? .zero
                )
                // One frame for the whole thumbnail, strip included: a drop
                // anywhere on it is a drop on this tab, so the strip never
                // resolves as a target of its own. Reported from OUTSIDE the
                // thumbnail, which offsets its own content, so the report is
                // its resting place; the coordinator's freeze while a reorder
                // is live is what actually guarantees that, since the
                // insertion index is counted against resting cells.
                .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .tab(id), layer: layer) }
            }
        case .newTab:
            NewTabPlaceholder(theme: theme, workspace: workspace.workspaceID)
        }
    }

    /// The accent outline: on whichever card owns the target, whether that is
    /// one of its thumbnails, a reorder among its own cells, or the card
    /// itself.
    private func isTargeted(_ tabs: [TabRecord]) -> Bool {
        switch drag.target {
        case .tabThumbnail?, .paneEdge?, .paneInterior?:
            let targeted = MiniPaneLayout.targetedTab(of: drag.target, dragging: drag.activeSubject, model: viewModel.model)
            return tabs.contains { $0.tabID == targeted }
        case .tabStrip?: return reorder.takesTheDrop
        default: return takesTheDrop
        }
    }

    /// What this card previews, keyed on the plan rather than on the resolved
    /// target: a tab dragged over its own workspace resolves to this card and
    /// commits nothing at all.
    private var preview: CardDropPreview {
        CardDropPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model)
    }

    private var reorder: CardReorderPreview {
        CardReorderPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model)
    }

    private var takesTheDrop: Bool { preview.takesTheDrop }
}

private struct TabThumbnail: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let tab: TabRecord
    let isTargeted: Bool
    /// How far this thumbnail slides to open the slot a reorder inside its
    /// card would land the dragged tab in.
    var displacement: CGSize = .zero

    @Environment(DragCoordinator.self) private var drag
    @Environment(\.displayScale) private var displayScale
    @Environment(\.gridThumbnailSize) private var thumbnailSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrangeTiles) private var tiles
    @Environment(\.dropReflowPreviewProgress) private var reflowHeld
    @State private var isOverThumbnail = false
    @State private var hoveredPane: PaneID?
    @GestureState private var pressed: ThumbnailPart?

    private var hovered: ThumbnailPart? {
        if let hoveredPane { return .pane(hoveredPane) }
        return isOverThumbnail ? .tab : nil
    }

    private func interaction(of part: ThumbnailPart) -> ControlInteraction {
        ThumbnailPart.interaction(of: part, hovered: hovered, pressed: pressed, dragInFlight: drag.activeSubject != nil)
    }

    private var tabTitle: String {
        viewModel.model.map { TabTitle.resolve(tab, in: $0).text } ?? tab.label
    }

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            GeometryReader { proxy in
                miniPanes(size: proxy.size)
            }
        }
        .frame(height: thumbnailSize.height)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .overlay { DropWash(theme: theme, isTargeted: isTargeted) }
        .overlay {
            RoundedRectangle(cornerRadius: ChromeRadius.surface)
                .strokeBorder(
                    ThumbnailPart.thumbnailOutline(theme: theme, tab: interaction(of: .tab)),
                    lineWidth: ChromeMetrics.ruleWidth
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .fadingHover($isOverThumbnail)
        // The handle and the padding around the mini panes mean the whole
        // tab; a mini pane's own tap is a descendant's and answers first.
        .onTapGesture { clicked(pane: nil) }
        // One element, not a group of mini pane titles to step through: the
        // thumbnail is a tile that selects its tab, and that is the whole of
        // what it offers. Undeclared it would not be an element at all --
        // SwiftUI folds a thumbnail into those titles and stamps the card's
        // identifier on each of them, which loses the thumbnail's own box.
        //
        // This must stay ABOVE the `.frame(maxWidth: .infinity)` below it.
        // Declared after that stretch, the element takes the stretched width
        // and every point aimed at a thumbnail as a fraction of its box lands
        // somewhere along the card instead, with nothing failing to build and
        // no test naming the modifier that moved.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tabTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { show() }
        .accessibilityIdentifier("flock.grid.tab.\(tab.tabID.rawValue)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(drag.isDragging(tab: tab.tabID) ? DragVisuals.originOpacity : 1)
        // On the whole thumbnail, mini panes included, so a press anywhere a
        // mini pane does not cover drags the tab. A mini pane's own gesture
        // is a descendant's, so it takes the press where it sits.
        .gesture(tabDrag.simultaneously(with: press))
        // Last, so everything above moves together and the frame the card
        // publishes from outside this view is the layout frame an offset
        // cannot touch. This is the strip's own shape (`TabBlock`).
        .offset(x: displacement.width, y: displacement.height)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
    }

    /// A click selects, a double-click goes there. Read off the event's own
    /// click count rather than a second, two-tap gesture: that one holds every
    /// single click back for the double-click interval before it answers.
    ///
    /// Guarded against the secondary button even though the grid has no
    /// context menu of its own: a double-click moves herdr's real focus, so an
    /// unguarded one jumps the terminal somewhere nothing on screen asked for.
    private func clicked(pane: PaneID?) {
        guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            show(pane: pane)
        } else if let selected = pane ?? tabsOwnPane {
            drag.selectGridPane(selected)
        }
    }

    /// The pane a click on the tab's handle selects: the one herdr has
    /// focused in it, or its first when that is not known.
    private var tabsOwnPane: PaneID? {
        let model = viewModel.model
        if let focused = model?.layouts[tab.tabID]?.focusedPane { return focused }
        return model?.panes.values.filter { $0.tabID == tab.tabID }.map(\.paneID).min { $0.rawValue < $1.rawValue }
    }

    /// What activating this thumbnail does, for the double-click and for the
    /// accessibility action alike: the tab, and the pane inside it when one
    /// was named. Selected before the grid closes, so the window never draws
    /// the previously selected tab in between.
    private func show(pane: PaneID? = nil) {
        ArrangeOpen.open(tab: tab.tabID, pane: pane, viewModel: viewModel, drag: drag)
    }

    private var titleStrip: some View {
        TabHandleStrip(
            theme: theme, title: tabTitle, status: tab.agentStatus, isBackground: viewModel.shownStatus(of: tab).isBackground,
            isFocusedTab: tab.tabID == viewModel.model?.focusedTabID,
            interaction: interaction(of: .tab)
        )
        .onHover { hovering in
            GridCursor.hover(hovering, dragInFlight: drag.holdsGrabCursor)
        }
    }

    /// Which part a press began on. Paired with each drag at that drag's
    /// own level: nested inside the tab's drag it would claim every press and
    /// the tab could never be picked up. Gesture state, so a press a tap or a
    /// drag takes over still clears.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressed) { _, state, _ in if state == nil { state = hovered ?? .tab } }
    }

    private var tabDrag: some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                let thumbnail = thumbnailFrame
                let size = thumbnail?.size ?? .zero
                drag.beginIfIdle(
                    .tab(tab.tabID),
                    ghost: DragCoordinator.Ghost(
                        title: tabTitle, symbol: "rectangle.stack",
                        originSize: size, isCompact: true, tabMiniature: miniature(size: size)
                    ),
                    at: value.startLocation,
                    home: home(box: CGRect(origin: .zero, size: size))
                )
            }
    }

    /// The tab as it looked when it was picked up, for a proxy that is a
    /// miniature of this very thumbnail. Its mini panes are laid out at the
    /// thumbnail's own pane area, so the proxy's panes land where the
    /// thumbnail's do.
    private func miniature(size: CGSize) -> DragCoordinator.Ghost.TabMiniature {
        let model = viewModel.model
        let paneArea = MiniPaneLayout.paneArea(
            in: CGRect(origin: .zero, size: size), stripHeight: ChromeMetrics.Grid.tabStripHeight
        )
        let panes = paneBoxes(size: paneArea.size).compactMap { placed -> DragCoordinator.Ghost.TabMiniature.Pane? in
            guard let pane = model?.panes[placed.pane] else { return nil }
            return .init(title: shownTitle(pane), status: pane.agentStatus, box: placed.frame)
        }
        return DragCoordinator.Ghost.TabMiniature(
            title: tabTitle, status: tab.agentStatus,
            isFocusedTab: tab.tabID == model?.focusedTabID, panes: panes
        )
    }

    /// On screen, in the drag space: what a mini pane's own frame is measured
    /// from, and what a released drag springs back onto.
    private var thumbnailFrame: CGRect? {
        drag.surfaces?.grid?.thumbnails.first { $0.id == tab.tabID }?.frame
    }

    /// The thumbnail this drag came from, carried as the grid item rather than
    /// as a rect: the grid scrolls and reflows under a drag. `box` is in the
    /// THUMBNAIL's own space, which a mini pane's box reaches by clearing the
    /// handle strip above it.
    private func home(box: CGRect) -> DragCoordinator.DragHome? {
        guard let thumbnail = thumbnailFrame else { return nil }
        return DragCoordinator.DragHome(
            atStart: CGRect(
                x: thumbnail.minX + box.minX, y: thumbnail.minY + box.minY,
                width: box.width, height: box.height
            ),
            item: .tab(tab.tabID),
            boxInItem: box
        )
    }

    /// A mini pane is a preview, never a surface, so the proxy is the mini
    /// pane's own footprint carrying the pane's title. `box` is in the mini
    /// pane AREA's space; the strip above it is what separates that from the
    /// thumbnail's own space.
    private func paneDrag(_ pane: PaneRecord, box: CGRect) -> some Gesture {
        let inThumbnail = MiniPaneLayout.boxInThumbnail(box, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        return DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                drag.beginIfIdle(
                    .pane(pane.paneID),
                    ghost: DragCoordinator.Ghost(
                        title: viewModel.model.map { PaneNaming.name(pane: pane, model: $0, oneTitle: viewModel.oneTitle) }
                            ?? pane.displayTitle,
                        symbol: "macwindow", originSize: box.size, isCompact: true
                    ),
                    at: value.startLocation,
                    home: home(box: inThumbnail)
                )
            }
    }

    private func shownTitle(_ pane: PaneRecord) -> String? {
        guard let model = viewModel.model else { return pane.displayTitle }
        return PaneNaming.shownTitle(pane: pane, model: model, oneTitle: viewModel.oneTitle)
    }

    /// This tab's mini panes inside a pane area of `size`. Shared with the
    /// drag proxy, so the proxy's panes land exactly where the thumbnail's do.
    private func paneBoxes(size: CGSize, arriving: MiniPaneLayout.Arrival? = nil) -> [MiniPaneLayout.Placed] {
        let model = viewModel.model
        let tabPanes = (model?.panes.values.filter { $0.tabID == tab.tabID } ?? [])
            .map(\.paneID)
            .sorted { $0.rawValue < $1.rawValue }
        return MiniPaneLayout.boxes(
            layout: model?.layouts[tab.tabID],
            exported: viewModel.exportedLayout(for: tab.tabID),
            fallbackPanes: tabPanes,
            size: size,
            padding: ChromeMetrics.Grid.thumbnailPadding,
            gap: ChromeMetrics.Grid.miniPaneGap,
            displayScale: displayScale > 0 ? displayScale : 2,
            arriving: arriving
        )
    }

    /// The pane a live drag would land in this tab, or nil when none would.
    private var arrival: MiniPaneLayout.Arrival? {
        MiniPaneLayout.arrival(of: drag.activeSubject, onto: drag.target, tab: tab.tabID, model: viewModel.model)
    }

    /// While a pane is about to land here the boxes are the ones the drop
    /// leaves behind, so the panes make room where it will really go and the
    /// slot it takes is drawn in the canvas's own preview language: the wash
    /// alone, a second coat over the one the targeted thumbnail already
    /// carries. The panes and the slot change under ONE animation, keyed on
    /// the whole reflow, so the slot opens by exactly what the panes give up.
    private func miniPanes(size: CGSize) -> some View {
        let model = viewModel.model
        let arriving = arrival
        let boxes = paneBoxes(size: size, arriving: arriving)
        let resting = arriving == nil ? boxes : paneBoxes(size: size)
        let preview = DropReflow(boxes: boxes, resting: resting, arriving: arriving)
        let reflow = reflowHeld.map {
            DropReflow.held(from: DropReflow(boxes: resting, resting: resting, arriving: nil), to: preview, progress: $0)
        } ?? preview
        return ZStack(alignment: .topLeading) {
            ForEach(reflow.panes, id: \.pane) { placed in
                if let pane = model?.panes[placed.pane] {
                    MiniPane(
                        theme: theme, title: shownTitle(pane), status: pane.agentStatus,
                        backgroundWork: viewModel.shownStatus(of: pane).backgroundWork,
                        isSelected: drag.gridSelection == pane.paneID,
                        interaction: interaction(of: .pane(pane.paneID)),
                        detail: tileBody(pane, box: placed.frame.size)
                    )
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.minX, y: placed.frame.minY)
                        .opacity(drag.isDragging(pane: pane.paneID) ? DragVisuals.originOpacity : 1)
                        .overlay(alignment: .top) { renameEditor(for: pane.paneID) }
                        .onTapGesture { clicked(pane: pane.paneID) }
                        .gesture(
                            paneDrag(pane, box: placed.frame).simultaneously(with: press),
                            including: renaming(pane.paneID) ? .subviews : .all
                        )
                        .contextMenu { paneMenu(pane.paneID) }
                        .onHover { hovering in
                            GridCursor.hover(hovering, dragInFlight: drag.holdsGrabCursor)
                            withAnimation(GridControlFade.animation(reduceMotion: reduceMotion)) {
                                if hovering { hoveredPane = pane.paneID } else if hoveredPane == pane.paneID { hoveredPane = nil }
                            }
                        }
                }
            }
            if let slot = reflow.slot {
                DropReflowSlot(theme: theme, frame: slot.frame)
                    .id(slot.key)
                    .transition(DropReflowSlot.transition(slot))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(DropReflowMotion.animation, value: reflow)
        // Published as data rather than as reported frames: a drop resolves
        // against where the mini panes REST, and every frame drawn here is
        // already the preview's answer to that resolution.
        .onAppear { publish(resting) }
        .onChange(of: resting) { _, boxes in publish(boxes) }
    }

    /// A mini pane's own menu. The tail is read when an item is chosen,
    /// never while the menu is built: built in `body`, it would redraw every
    /// thumbnail on every read.
    @ViewBuilder
    private func paneMenu(_ pane: PaneID) -> some View {
        Button("Rename Pane") { viewModel.beginRename(.pane(pane)) }
            .accessibilityIdentifier("flock.grid.pane.rename")
        Button("Copy Output") {
            guard let text = PaneOutputCopy.text(of: viewModel.paneTails[pane]) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .accessibilityIdentifier("flock.grid.pane.copyOutput")
        Divider()
        Button("Close Pane") { Task { await viewModel.closePane(pane) } }
            .accessibilityIdentifier("flock.grid.pane.close")
    }

    /// What a rename opened on `pane` edits: the pane, or the tab standing for
    /// it when the pane has no title of its own.
    private func renaming(_ pane: PaneID) -> Bool {
        viewModel.renameTarget != nil && viewModel.renameTarget == viewModel.renameTarget(for: .pane(pane))
    }

    /// The editor sits over the top of the tile, which a tile has no label
    /// row to host in.
    @ViewBuilder
    private func renameEditor(for pane: PaneID) -> some View {
        if renaming(pane) {
            let target = viewModel.renameTarget(for: .pane(pane))
            InlineRenameField(
                theme: theme, font: ChromeType.gridMiniPaneTitle, initialText: viewModel.renameText(for: target),
                accessibilityIdentifier: "flock.grid.rename.\(pane.rawValue)",
                onCommit: { text in Task { await viewModel.commitRename(text, for: target) } },
                onCancel: { viewModel.cancelRename() }
            )
            .padding(ChromeMetrics.Grid.miniPaneHorizontalPadding)
        }
    }

    /// Nil for a box too small to read, which keeps the status word.
    private func tileBody(_ pane: PaneRecord, box: CGSize) -> AnyView? {
        let detail = TileDetail.of(box: box)
        guard detail >= .tail else { return nil }
        return AnyView(ArrangeTileBody(
            theme: theme, viewModel: viewModel, pane: pane, title: shownTitle(pane),
            shown: viewModel.shownStatus(of: pane), detail: detail
        ))
    }

    /// The boxes a drop inside this thumbnail is hit-tested against, in the
    /// thumbnail's own space: the strip above the pane area is what separates
    /// the two, and a point it covers is the tab's own handle.
    private func publish(_ boxes: [MiniPaneLayout.Placed]) {
        drag.setGridMiniPanes(
            MiniPaneLayout.boxesInThumbnail(boxes, stripHeight: ChromeMetrics.Grid.tabStripHeight), for: tab.tabID,
            layer: tiles.isZoomed ? .zoomed : .grid
        )
    }
}

/// A tab's handle: the top of its thumbnail carrying the title and status
/// dot. Shared with the drag proxy, which draws a whole tab as a miniature of
/// its own thumbnail and has to use the same roles. No fill; the tab you came
/// from is underlined as the tab strip underlines a selected tab.
struct TabHandleStrip: View {
    let theme: Theme
    let title: String
    let status: AgentStatus
    var isBackground = false
    let isFocusedTab: Bool
    var interaction: ControlInteraction = .rest

    var body: some View {
        let appearance = GridControlAppearance.resolve(
            theme: theme, restForeground: isFocusedTab ? theme.textStrong : theme.textDim,
            isHovering: interaction.isHovering, isPressed: interaction.isPressed
        )
        HStack(spacing: ChromeMetrics.Grid.tabStripSpacing) {
            Text(title)
                .font(ChromeType.gridTabLabel(selected: isFocusedTab))
                .foregroundStyle(appearance.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
            StatusDot(status: status, theme: theme, size: ChromeMetrics.Grid.labelStatusDot, isBackground: isBackground)
        }
        .padding(.horizontal, ChromeMetrics.Grid.tabStripHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ChromeMetrics.Grid.tabStripHeight)
        .background(
            GridControlGround(theme: theme, shape: AnyShape(Rectangle()), restFill: .clear, appearance: appearance)
        )
        .overlay(alignment: .bottom) {
            if isFocusedTab {
                Rectangle().fill(theme.accent).frame(height: ChromeMetrics.Grid.currentTabUnderline).allowsHitTesting(false)
            }
        }
    }
}

/// A pane in miniature: its status word and title, nothing else. Takes the
/// two values rather than a `PaneRecord` so the drag proxy, which carries a
/// snapshot of what was picked up, can draw the same box.
///
/// Outlined only when blocked or previewed: a blocked pane is the one outline
/// inside an island, so it is found at a glance.
struct MiniPane: View {
    let theme: Theme
    /// nil draws the status word alone: the tab's title above stands for it.
    let title: String?
    let status: AgentStatus
    var backgroundWork: String? = nil
    /// The pane Arrange has selected, which Return opens.
    var isSelected = false
    var interaction: ControlInteraction = .rest
    /// Drawn in place of the status word and title: the pane's own output,
    /// for a box large enough to read it (`ArrangeTileBody`).
    var detail: AnyView? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeRadius.control)
        // A narrow box gives up title lines before the status word; one too
        // short for the status word over the title, as a stacked split at the
        // 120pt floor is, keeps the dot and the title on one line rather than
        // clipping the title away.
        Group {
            if let detail {
                detail
            } else {
                ViewThatFits(in: .vertical) {
                    stacked(titleLines: title == nil ? 0 : 3)
                    stacked(titleLines: title == nil ? 0 : 1)
                    HStack(spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
                        dot
                        if title == nil { statusWord } else { titleText.lineLimit(1) }
                    }
                    .padding(.vertical, ChromeMetrics.Grid.thumbnailPadding)
                    .padding(.horizontal, ChromeMetrics.Grid.miniPaneTitleSpacing + ChromeMetrics.Grid.thumbnailPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if let wash = statusWash { wash.opacity(ChromeMetrics.Grid.statusWashOpacity) }
        }
        // The terminal's own ground, held through hover and press: a screen
        // read draws on what the pane itself draws on, and an app's painted
        // background must keep blending into it. The ring marks hover.
        .background(theme.pane, in: shape)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                ThumbnailPart.paneOutline(theme: theme, status: status, isSelected: isSelected, pane: interaction),
                lineWidth: outlineWidth
            )
        )
        .contentShape(Rectangle())
    }

    private var shown: ShownStatus { ShownStatus(status, backgroundWork: backgroundWork) }

    private var statusWash: Color? {
        guard !shown.isBackground, shown.status == .done || shown.status == .blocked else { return nil }
        return theme.agentStatusMarkColor(shown.status)
    }

    /// The blocked and previewed outlines are the island's alarms; a hover
    /// ring is a lighter mark so it never reads as one.
    private var outlineWidth: CGFloat {
        if isSelected { return ChromeMetrics.selectionOutlineWidth }
        return status == .blocked ? ChromeMetrics.Grid.miniPaneBlockedOutline : ChromeMetrics.ruleWidth
    }

    private func stacked(titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
            HStack(spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
                dot
                statusWord
            }
            if titleLines > 0 { titleText.lineLimit(titleLines) }
        }
        .padding(.vertical, ChromeMetrics.Grid.miniPaneVerticalPadding)
        .padding(.horizontal, ChromeMetrics.Grid.miniPaneHorizontalPadding)
    }

    /// The reason alone for background work: a mini pane is too narrow for
    /// anything longer, and its mark already says background.
    private var statusWord: some View {
        Text(backgroundWork ?? status.rawValue)
            .font(ChromeType.gridMiniPaneStatus)
            .foregroundStyle(backgroundWork != nil ? theme.backgroundWorkColor : status == .blocked ? theme.red : theme.textLabel)
            .lineLimit(1)
    }

    private var dot: some View {
        StatusDot(shown: ShownStatus(status, backgroundWork: backgroundWork), theme: theme, size: ChromeMetrics.Grid.miniPaneStatusDot)
    }

    private var titleText: Text {
        Text(title ?? "").font(ChromeType.gridMiniPaneTitle).foregroundStyle(theme.textStrong)
    }
}

private struct GridThumbnailSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: ChromeMetrics.Grid.thumbnailWidth, height: ChromeMetrics.Grid.thumbnailHeight)
}

extension EnvironmentValues {
    /// Arrange's one thumbnail size, chosen per window by `IslandLayout.fit`.
    var gridThumbnailSize: CGSize {
        get { self[GridThumbnailSizeKey.self] }
        set { self[GridThumbnailSizeKey.self] = newValue }
    }
}

/// The tab a drop on this card's empty space is about to create, drawn in the
/// slot that tab will take. Its own cell comes from `GridCardLayout`, so the
/// card's rows place it exactly as they place a real thumbnail. It reports a
/// frame but is never a drop surface: the card behind it is what answers.
///
/// The wash alone, never a stroke, which is how the canvas previews a drop;
/// the strip band takes a second coat of it so the tab's own handle shape
/// still reads inside an otherwise empty slot. Over `pane`, which is the
/// ground a real thumbnail's own wash lands on, so a slot standing in for a
/// tab and a thumbnail taking a drop are the same drawing over the same
/// ground.
private struct NewTabPlaceholder: View {
    let theme: Theme
    let workspace: WorkspaceID

    @Environment(\.gridThumbnailSize) private var thumbnailSize

    var body: some View {
        VStack(spacing: 0) {
            Text("new tab")
                .font(ChromeType.gridTabLabel(selected: false))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .padding(.horizontal, ChromeMetrics.Grid.tabStripHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: ChromeMetrics.Grid.tabStripHeight)
                .background(theme.accent.opacity(DragVisuals.dropWashOpacity))
            Color.clear
        }
        .frame(maxWidth: .infinity)
        .frame(height: thumbnailSize.height)
        .background(theme.accent.opacity(DragVisuals.dropWashOpacity), in: RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .accessibilityIdentifier("flock.grid.newTab.\(workspace.rawValue)")
        .allowsHitTesting(false)
    }
}

/// The grid's pointer shapes, which are rearrange mode's: an open hand over
/// anything draggable, and nothing at all while a drag is live, since
/// `DragCoordinator` has already pushed the closed hand for the whole app and
/// a `set` here would paint over that push with nothing to pop it back off.
private enum GridCursor {
    static func hover(_ hovering: Bool, dragInFlight: Bool) {
        guard !dragInFlight else { return }
        (hovering ? NSCursor.openHand : NSCursor.arrow).set()
    }
}

private struct DropWash: View {
    let theme: Theme
    let isTargeted: Bool
    var cornerRadius: CGFloat = ChromeRadius.surface

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(theme.accent.opacity(DragVisuals.dropWashOpacity))
            .opacity(isTargeted ? 1 : 0)
            .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: isTargeted)
            .allowsHitTesting(false)
    }
}
