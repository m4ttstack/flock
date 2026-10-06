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
    @Environment(DormantCutoffStore.self) private var cutoff
    @State private var scrollPosition = ScrollPosition()
    /// The fit on screen. Written only while no drag is live, so the fit a
    /// drag starts with is the one it keeps (`IslandFitHold`).
    @State private var hold = IslandFitHold()
    /// The space the islands can use: the scroll view less the canvas
    /// padding on each side.
    @State private var viewport: CGSize = .zero
    /// Dormant workspaces opened by a click, until the view closes.
    @State private var openedDormant: Set<WorkspaceID> = []
    /// Dormant workspaces sprung open by a dwell, until that drag ends.
    @State private var sprungDormant: Set<WorkspaceID> = []

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.rule)
                .frame(height: ChromeMetrics.ruleWidth)
            if shownMode == .missionControl {
                MissionControlView(theme: theme, viewModel: viewModel)
            } else {
                arrangeGrid
            }
        }
        .boundedBackground(theme.chrome)
        .onAppear {
            mode.opened(dragInFlight: drag.activeSubject != nil)
            refreshIdentities()
            drag.setGridOrder(publishedOrder)
        }
        .onChange(of: itemOrder) { drag.setGridOrder(publishedOrder) }
        .onChange(of: shownMode) { drag.setGridOrder(publishedOrder) }
    }

    private var shownMode: AllWorkspacesMode { mode.shown(dragInFlight: drag.activeSubject != nil) }

    /// Mission control is never a drop target, so it publishes no items.
    private var publishedOrder: [GridItemID] { shownMode == .arrange ? itemOrder : [] }

    private var arrangeGrid: some View {
        let arrange = self.arrange
        let fit = arrange.fit
        let metrics = ChromeMetrics.Grid.islands
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: metrics.islandGap) {
                ForEach(fit.rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: metrics.islandGap) {
                        ForEach(row, id: \.self) { id in
                            if let workspace = workspaces.first(where: { $0.workspaceID == id }) {
                                WorkspaceIsland(
                                    theme: theme, viewModel: viewModel, workspace: workspace,
                                    slotsPerRow: fit.tabsPerRow[id] ?? 1,
                                    identity: arrange.sections.flatMap {
                                        MissionBoard.identityColor(id, sections: $0, identity: identity, theme: theme)
                                    },
                                    identityKey: arrange.sections.flatMap { WorkspaceIdentityStore.key(for: id, sections: $0) }
                                )
                            }
                        }
                    }
                    // Islands sharing a row share the taller one's height.
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !arrange.chips.isEmpty { dormantStrip(arrange.chips) }
            }
            .environment(\.gridThumbnailSize, CGSize(width: fit.thumbnailWidth, height: fit.thumbnailHeight))
            .padding(ChromeMetrics.Grid.canvasPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .coordinateSpace(.named(DragSpace.gridContent))
            .reportsDragFrame { drag.setGridContentOrigin($0.origin) }
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
            sprungDormant = []
            holdFit(self.arrange.inputs)
        }
        .onDisappear { openedDormant = [] }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollPosition($scrollPosition)
        .reportsScrollExtent(.vertical) { drag.setGridScroll(offset: $0, maximumOffset: $1) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .boundedBackground(theme.canvas)
        // A click anywhere a thumbnail does not claim puts the preview
        // away. Applied before the overlay, so a click on the card itself
        // never reaches it.
        .contentShape(Rectangle())
        .onTapGesture { drag.dismissGridPreview() }
        .overlay(alignment: .topLeading) { GridPreviewCard(theme: theme, viewModel: viewModel) }
        .reportsDragFrame { drag.gridViewport = $0 }
        .onAppear { drag.gridScroller = { y in scrollPosition.scrollTo(y: y) } }
    }

    private var header: some View {
        HStack(spacing: ChromeMetrics.Grid.headerSpacing) {
            modeToggle
            Text(workspaces.count == 1 ? "1 workspace" : "\(workspaces.count) workspaces")
                .font(ChromeType.gridCount)
                .foregroundStyle(theme.textLabel)
            Spacer(minLength: 0)
            Text(shownMode == .missionControl ? "⌘J oldest · ⇧⌘J back · esc" : "esc to return")
                .font(ChromeType.gridHint)
                .foregroundStyle(theme.textLabel)
        }
        .padding(.horizontal, ChromeMetrics.Grid.headerHorizontalPadding)
        .frame(height: ChromeMetrics.Grid.headerHeight)
        .background(WindowDragExclusion())
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach(AllWorkspacesMode.allCases, id: \.self) { option in
                let on = shownMode == option
                Button { mode.select(option) } label: {
                    Text(option.title)
                        .font(ChromeType.modeToggle(selected: on))
                        .foregroundStyle(on ? theme.textStrong : theme.textLabel)
                        .padding(.horizontal, ChromeMetrics.MissionControl.toggleSegmentPadding)
                        .frame(height: ChromeMetrics.MissionControl.toggleHeight - 4)
                        .background(
                            on ? theme.selection : .clear,
                            in: RoundedRectangle(cornerRadius: ChromeMetrics.MissionControl.toggleCornerRadius - 2)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flock.grid.mode.\(option.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(theme.tabRest, in: RoundedRectangle(cornerRadius: ChromeMetrics.MissionControl.toggleCornerRadius))
    }

    private func refreshIdentities() {
        guard let model = viewModel.model, !model.workspaces.isEmpty else { return }
        let keys = WorkspaceIdentityStore.keys(in: RailSections(model: model, board: boardNames, herdProgress: herdProgress))
        identity.keepOnly(Set(keys))
        identity.assign(keys)
    }

    /// What Arrange draws: the islands as the fit lays them out, and the
    /// dormant workspaces left as chips.
    private struct Arrangement {
        struct Inputs: Equatable {
            let islands: [IslandLayout.Island]
            let viewport: CGSize
            let hasDormantStrip: Bool
        }

        let sections: RailSections?
        let inputs: Inputs
        let fit: IslandLayout.Fit
        let chips: [WorkspaceRecord]
    }

    private var arrange: Arrangement {
        let model = viewModel.model
        let made = MissionBoard.make(
            viewModel: viewModel, board: boardNames, herdProgress: herdProgress, cutoff: cutoff, now: viewModel.currentTime
        )
        let sections = made?.1
        let ranked = sections?.railOrder ?? []
        let ordered = ranked.compactMap { id in workspaces.first { $0.workspaceID == id } }
            + workspaces.filter { !ranked.contains($0.workspaceID) }
        let dormant = (made?.0.dormantWorkspaces ?? []).subtracting(openedDormant).subtracting(sprungDormant)
        let islands = ordered.filter { !dormant.contains($0.workspaceID) }.map {
            IslandLayout.Island(id: $0.workspaceID, tabs: model?.tabs[$0.workspaceID]?.count ?? 1)
        }
        let inputs = Arrangement.Inputs(islands: islands, viewport: viewport, hasDormantStrip: !dormant.isEmpty)
        // A copy, so `body` never writes state; `holdFit` keeps the stored one.
        var held = hold
        var fit = held.update(
            islands, in: viewport, hasDormantStrip: inputs.hasDormantStrip, dragging: drag.activeSubject != nil,
            metrics: ChromeMetrics.Grid.islands
        )
        let drawn = Set(fit.rows.joined())
        fit = fit.appending(islands.filter { !drawn.contains($0.id) }, width: viewport.width, metrics: ChromeMetrics.Grid.islands)
        let shown = Set(fit.rows.joined())
        let chips = ordered.filter { dormant.contains($0.workspaceID) && !shown.contains($0.workspaceID) }
        return Arrangement(sections: sections, inputs: inputs, fit: fit, chips: chips)
    }

    private func holdFit(_ inputs: Arrangement.Inputs) {
        guard drag.activeSubject == nil else { return }
        _ = hold.update(
            inputs.islands, in: inputs.viewport, hasDormantStrip: inputs.hasDormantStrip, dragging: false,
            metrics: ChromeMetrics.Grid.islands
        )
    }

    private func dormantStrip(_ chips: [WorkspaceRecord]) -> some View {
        HStack(spacing: ChromeMetrics.Grid.dormantChipSpacing) {
            Text("DORMANT")
                .font(ChromeType.missionLaneTitle)
                .tracking(1.28)
                .foregroundStyle(theme.textLabel)
                .padding(.trailing, ChromeMetrics.Grid.dormantChipSpacing)
            ForEach(chips, id: \.workspaceID) { workspace in
                DormantChip(theme: theme, viewModel: viewModel, workspace: workspace) {
                    openedDormant.insert(workspace.workspaceID)
                } springOpen: {
                    sprungDormant.insert(workspace.workspaceID)
                }
            }
        }
        .frame(height: ChromeMetrics.Grid.islands.dormantStripHeight - ChromeMetrics.Grid.islands.islandGap, alignment: .bottom)
    }

    /// The items a drop can hit, in grid order: what turns their frames back
    /// into a list and drops the frame of an item no longer shown. `.newTab`
    /// names the rect the created tab lands in, whichever cell is drawing it.
    /// A chip is a card with no cells: a drop on it lands in a new tab.
    private var itemOrder: [GridItemID] {
        let arrange = self.arrange
        let chips = arrange.chips.map { GridItemID.card($0.workspaceID) }
        let drawn = arrange.fit.rows.joined().filter { id in workspaces.contains { $0.workspaceID == id } }
        return drawn.flatMap { id -> [GridItemID] in
            let tabs = (viewModel.model?.tabs[id] ?? []).map(\.tabID)
            let preview = CardDropPreview(workspace: id, drag: drag, model: viewModel.model)
            let cells = preview.cells(of: tabs, perRow: arrange.fit.tabsPerRow[id] ?? 1)
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
        } + chips
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

private struct WorkspaceIsland: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let workspace: WorkspaceRecord
    /// The fit's slot count for this island, so the cells it draws and the
    /// ids the grid publishes for them are laid out against one count.
    let slotsPerRow: Int
    let identity: Color?
    /// Nil for a herd, which takes no colour of its own.
    let identityKey: String?

    @Environment(DragCoordinator.self) private var drag
    @Environment(WorkspaceIdentityStore.self) private var identityStore
    @Environment(\.gridThumbnailSize) private var thumbnailSize

    private var isFocusedWorkspace: Bool { workspace.workspaceID == viewModel.model?.focusedWorkspaceID }

    var body: some View {
        let tabs = viewModel.model?.tabs[workspace.workspaceID] ?? []
        let rows = GridCardLayout.rows(preview.cells(of: tabs.map(\.tabID), perRow: slotsPerRow), perRow: slotsPerRow)
        // Read once per island rather than per cell: only the island a
        // reorder is over, and only while that reorder commits, has any.
        let displacements = reorder.displacements
        let metrics = ChromeMetrics.Grid.islands
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.Grid.islandCornerRadius)
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
        .background((identity ?? theme.textLabel).opacity(ChromeMetrics.Grid.islandTint), in: shape)
        .overlay { DropWash(theme: theme, isTargeted: takesTheDrop, cornerRadius: ChromeMetrics.Grid.islandCornerRadius) }
        .overlay(shape.strokeBorder(outline(tabs), lineWidth: ChromeMetrics.Grid.islandCurrentOutline))
        .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: isTargeted(tabs))
        .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .card(workspace.workspaceID)) }
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
        if isFocusedWorkspace, let identity { return identity }
        return .clear
    }

    private func header(tabCount: Int) -> some View {
        HStack(spacing: ChromeMetrics.Grid.islandHeaderSpacing) {
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.identitySquareRadius)
                .fill(identity ?? theme.textLabel)
                .frame(width: ChromeMetrics.Grid.identitySquare, height: ChromeMetrics.Grid.identitySquare)
            Text(workspace.label)
                .font(ChromeType.gridCardName)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
            StatusDot(status: workspace.agentStatus, theme: theme, size: ChromeMetrics.Grid.cardStatusDot + 2)
            Spacer(minLength: 0)
            Text(tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
                .font(ChromeType.gridCardMeta)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: ChromeMetrics.Grid.islandHeaderHeight)
        .padding(.bottom, ChromeMetrics.Grid.islandHeaderGap)
        .contentShape(Rectangle())
        .contextMenu { colourMenu }
    }

    @ViewBuilder
    private var colourMenu: some View {
        if let identityKey {
            let colors = IdentityPalette.colors(for: theme.palette)
            ForEach(Array(colors.enumerated()), id: \.offset) { index, rgb in
                Button {
                    identityStore.setOverride(index, for: identityKey)
                } label: {
                    Label { Text("Colour \(index + 1)") } icon: { Image(nsImage: IdentitySwatch.image(rgb)) }
                }
                .accessibilityIdentifier("flock.grid.island.colour.\(index)")
            }
            Divider()
            Button("Automatic") { identityStore.setOverride(nil, for: identityKey) }
                .accessibilityIdentifier("flock.grid.island.colour.automatic")
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
                        drag.setGridItemFrame($0, for: .newTab(workspace.workspaceID))
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
                    displacement: displacements[id] ?? .zero,
                    handleFill: isFocusedWorkspace && id == viewModel.model?.focusedTabID
                        ? identity?.opacity(ChromeMetrics.Grid.selectedHandleTint) : nil
                )
                // One frame for the whole thumbnail, strip included: a drop
                // anywhere on it is a drop on this tab, so the strip never
                // resolves as a target of its own. Reported from OUTSIDE the
                // thumbnail, which offsets its own content, so the report is
                // its resting place; the coordinator's freeze while a reorder
                // is live is what actually guarantees that, since the
                // insertion index is counted against resting cells.
                .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .tab(id)) }
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
    /// The handle's fill: only the tab you came from takes one.
    var handleFill: Color?

    @Environment(DragCoordinator.self) private var drag
    @Environment(\.displayScale) private var displayScale
    @Environment(\.gridThumbnailSize) private var thumbnailSize

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
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .overlay { DropWash(theme: theme, isTargeted: isTargeted) }
        .contentShape(Rectangle())
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
        .gesture(tabDrag)
        // Last, so everything above moves together and the frame the card
        // publishes from outside this view is the layout frame an offset
        // cannot touch. This is the strip's own shape (`TabBlock`).
        .offset(x: displacement.width, y: displacement.height)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
    }

    /// A click previews, a double-click goes there. Read off the event's own
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
        } else if let previewed = pane ?? tabsOwnPane {
            drag.showGridPreview(pane: previewed)
        }
    }

    /// The pane a click on the tab's handle previews: the one herdr has
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
        viewModel.select(tab: tab.tabID)
        drag.closeGrid()
        Task {
            await viewModel.jumpToHerdr(tab: tab.tabID)
            if let pane { await viewModel.jumpToHerdr(pane: pane) }
        }
    }

    private var titleStrip: some View {
        TabHandleStrip(
            theme: theme, title: tabTitle, status: tab.agentStatus,
            isFocusedTab: tab.tabID == viewModel.model?.focusedTabID, fill: handleFill
        )
        .onHover { hovering in
            GridCursor.hover(hovering, dragInFlight: drag.holdsGrabCursor)
        }
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
            return .init(title: pane.displayTitle, status: pane.agentStatus, box: placed.frame)
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
                        title: pane.displayTitle, symbol: "macwindow", originSize: box.size, isCompact: true
                    ),
                    at: value.startLocation,
                    home: home(box: inThumbnail)
                )
            }
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
    /// carries.
    private func miniPanes(size: CGSize) -> some View {
        let model = viewModel.model
        let arriving = arrival
        let boxes = paneBoxes(size: size, arriving: arriving)
        let resting = arriving == nil ? boxes : paneBoxes(size: size)
        return ZStack(alignment: .topLeading) {
            ForEach(boxes, id: \.pane) { placed in
                if placed.pane == arriving?.pane {
                    RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius)
                        .fill(theme.accent.opacity(DragVisuals.dropWashOpacity))
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.minX, y: placed.frame.minY)
                        .allowsHitTesting(false)
                } else if let pane = model?.panes[placed.pane] {
                    MiniPane(
                        theme: theme, title: pane.displayTitle, status: pane.agentStatus,
                        isPreviewed: drag.gridPreviewCard == pane.paneID
                    )
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.minX, y: placed.frame.minY)
                        .opacity(drag.isDragging(pane: pane.paneID) ? DragVisuals.originOpacity : 1)
                        .onTapGesture { clicked(pane: pane.paneID) }
                        .gesture(paneDrag(pane, box: placed.frame))
                        .onHover { GridCursor.hover($0, dragInFlight: drag.holdsGrabCursor) }
                        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: placed.frame)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Published as data rather than as reported frames: a drop resolves
        // against where the mini panes REST, and every frame drawn here is
        // already the preview's answer to that resolution.
        .onAppear { publish(resting) }
        .onChange(of: resting) { _, boxes in publish(boxes) }
    }

    /// The boxes a drop inside this thumbnail is hit-tested against, in the
    /// thumbnail's own space: the strip above the pane area is what separates
    /// the two, and a point it covers is the tab's own handle.
    private func publish(_ boxes: [MiniPaneLayout.Placed]) {
        drag.setGridMiniPanes(
            MiniPaneLayout.boxesInThumbnail(boxes, stripHeight: ChromeMetrics.Grid.tabStripHeight), for: tab.tabID
        )
    }
}

/// A tab's handle: the top of its thumbnail carrying the title and status
/// dot. Shared with the drag proxy, which draws a whole tab as a miniature of
/// its own thumbnail and has to use the same roles. No fill but the one the
/// island hands the tab you came from.
struct TabHandleStrip: View {
    let theme: Theme
    let title: String
    let status: AgentStatus
    let isFocusedTab: Bool
    var fill: Color?

    var body: some View {
        HStack(spacing: ChromeMetrics.Grid.tabStripSpacing) {
            Text(title)
                .font(ChromeType.gridTabLabel(selected: isFocusedTab))
                .foregroundStyle(isFocusedTab ? theme.textStrong : theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 0)
            StatusDot(status: status, theme: theme, size: ChromeMetrics.Grid.labelStatusDot)
        }
        .padding(.horizontal, ChromeMetrics.Grid.tabStripHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ChromeMetrics.Grid.tabStripHeight)
        .background(fill ?? .clear)
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
    let title: String
    let status: AgentStatus
    /// Its preview card is the one open, so the card's pane is findable.
    var isPreviewed = false

    var body: some View {
        // A narrow box gives up title lines before the status word; one too
        // short for the status word over the title, as a stacked split at the
        // 120pt floor is, keeps the dot and the title on one line rather than
        // clipping the title away.
        ViewThatFits(in: .vertical) {
            stacked(titleLines: 3)
            stacked(titleLines: 1)
            HStack(spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
                dot
                titleText.lineLimit(1)
            }
            .padding(.vertical, ChromeMetrics.Grid.thumbnailPadding)
            .padding(.horizontal, ChromeMetrics.Grid.miniPaneTitleSpacing + ChromeMetrics.Grid.thumbnailPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.tabRest, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius)
                .strokeBorder(outline, lineWidth: ChromeMetrics.Grid.miniPaneBlockedOutline)
        )
        .contentShape(Rectangle())
    }

    private func stacked(titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
            HStack(spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
                dot
                Text(status.rawValue)
                    .font(ChromeType.gridMiniPaneStatus)
                    .foregroundStyle(status == .blocked ? theme.red : theme.textLabel)
                    .lineLimit(1)
            }
            titleText.lineLimit(titleLines)
        }
        .padding(.vertical, ChromeMetrics.Grid.miniPaneVerticalPadding)
        .padding(.horizontal, ChromeMetrics.Grid.miniPaneHorizontalPadding)
    }

    private var dot: some View {
        StatusDot(status: status, theme: theme, size: ChromeMetrics.Grid.miniPaneStatusDot)
    }

    private var titleText: Text {
        Text(title).font(ChromeType.gridMiniPaneTitle).foregroundStyle(theme.textStrong)
    }

    private var outline: Color {
        if isPreviewed { return theme.accent }
        return status == .blocked ? theme.red : .clear
    }
}

/// The identity colours as menu images: a menu draws a symbol as a template,
/// which would drop the very colour the item names.
private enum IdentitySwatch {
    static func image(_ rgb: RGB) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(
                srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1
            ).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
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

/// A dormant workspace in the strip: a drop target that creates a tab there,
/// and that springs open as a full island when a drag dwells on it.
private struct DormantChip: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let workspace: WorkspaceRecord
    let open: () -> Void
    let springOpen: () -> Void

    @Environment(DragCoordinator.self) private var drag

    private var isDwelledOn: Bool {
        drag.activeSubject != nil && drag.target == .workspaceThumbnail(workspace.workspaceID)
    }

    var body: some View {
        let takesTheDrop = CardDropPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model).takesTheDrop
        HStack(spacing: 7) {
            StatusDot(status: workspace.agentStatus, theme: theme, size: 8)
            Text(workspace.label)
                .font(ChromeType.gridCardMeta)
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: ChromeMetrics.Grid.dormantChipHeight)
        .background(theme.chrome, in: Capsule())
        .overlay { DropWash(theme: theme, isTargeted: takesTheDrop, cornerRadius: ChromeMetrics.Grid.dormantChipHeight / 2) }
        .overlay(Capsule().strokeBorder(takesTheDrop ? theme.accent : .clear, lineWidth: ChromeMetrics.Grid.islandCurrentOutline))
        .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .card(workspace.workspaceID)) }
        .contentShape(Capsule())
        .onTapGesture { open() }
        .task(id: isDwelledOn) {
            guard isDwelledOn else { return }
            try? await Task.sleep(for: ChromeMetrics.Grid.dormantDwell)
            guard !Task.isCancelled, isDwelledOn else { return }
            springOpen()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("flock.grid.dormant.\(workspace.workspaceID.rawValue)")
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
        .background(theme.accent.opacity(DragVisuals.dropWashOpacity), in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
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
    var cornerRadius: CGFloat = ChromeMetrics.Grid.thumbnailCornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(theme.accent.opacity(DragVisuals.dropWashOpacity))
            .opacity(isTargeted ? 1 : 0)
            .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: isTargeted)
            .allowsHitTesting(false)
    }
}

/// Drawn over the grid's scroll view rather than inside a card, so it is
/// never clipped by the card or the row below it.
private struct GridPreviewCard: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag
    @State private var size = CGSize(width: ChromeMetrics.HoverCard.width, height: ChromeMetrics.HoverCard.estimatedHeight)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if drag.gridPreviewCard != nil {
                scrim.transition(.opacity)
            }
            card
        }
        .animation(.easeOut(duration: ChromeMetrics.HoverCard.openDuration), value: drag.gridPreviewCard)
    }

    /// Takes no clicks: the grid behind stays live, so a click on another
    /// pane moves the card and a click on empty space puts it away.
    private var scrim: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? ChromeMetrics.HoverCard.lightScrimOpacity : ChromeMetrics.HoverCard.darkScrimOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var card: some View {
        if let previewed = drag.gridPreviewCard,
           let viewport = drag.gridViewport,
           let box = drag.gridPaneFrame(of: previewed),
           let model = viewModel.model,
           let pane = model.panes[previewed],
           let content = PaneHoverCardContent.make(
               pane: previewed, model: model, exported: viewModel.exportedLayout(for: pane.tabID), homeDirectory: NSHomeDirectory()
           ) {
            let paneBox = box.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
            let origin = HoverCardPlacement.origin(
                pane: paneBox, card: size, container: CGRect(origin: .zero, size: viewport.size),
                gap: ChromeMetrics.HoverCard.paneGap
            )
            PaneHoverCardView(
                theme: theme, content: content, tail: viewModel.paneTail(for: previewed),
                open: { openPane(previewed, tab: pane.tabID) },
                close: { drag.dismissGridPreview() }
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .shadow(
                color: .black.opacity(ChromeMetrics.HoverCard.shadowOpacity),
                radius: ChromeMetrics.HoverCard.shadowRadius, y: ChromeMetrics.HoverCard.shadowY
            )
            // A card moving to another pane is a new card, so it grows out of
            // that pane rather than sliding across the grid from the last one.
            .id(previewed)
            .transition(
                .scale(scale: ChromeMetrics.HoverCard.openScale, anchor: Self.anchor(toward: paneBox, from: origin, card: size))
                    .combined(with: .opacity)
            )
            .offset(x: origin.x, y: origin.y)
            // The card is not draggable, so the open hand the pane under the
            // pointer set has no meaning over it.
            .onHover { if $0 { GridCursor.hover(false, dragInFlight: drag.holdsGrabCursor) } }
            // The card's own cadence, and the whole of what keeps a running
            // pane's tail current: nothing herdr reports about a pane changes
            // when it prints, so there is no event to follow. Cancelled with
            // the card, so no pane is read once its card has gone.
            .task(id: previewed) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: PaneTailPolicy.refreshInterval)
                    guard !Task.isCancelled else { return }
                    viewModel.refreshPaneTail(for: previewed)
                }
            }
        }
    }

    private func openPane(_ pane: PaneID, tab: TabID) {
        viewModel.select(tab: tab)
        drag.closeGrid()
        Task {
            await viewModel.jumpToHerdr(tab: tab)
            await viewModel.jumpToHerdr(pane: pane)
        }
    }

    /// The point of the card nearest the pane it describes, so the card grows
    /// out of that pane.
    private static func anchor(toward pane: CGRect, from origin: CGPoint, card: CGSize) -> UnitPoint {
        guard card.width > 0, card.height > 0 else { return .center }
        return UnitPoint(
            x: min(max((pane.midX - origin.x) / card.width, 0), 1),
            y: min(max((pane.midY - origin.y) / card.height, 0), 1)
        )
    }
}

private struct PaneHoverCardView: View {
    let theme: Theme
    let content: PaneHoverCardContent
    let tail: PaneTail?
    let open: () -> Void
    let close: () -> Void

    @State private var tailHeight: CGFloat = 0
    @State private var tailScroll = ScrollPosition(edge: .bottom)
    @State private var followsTail = true
    @State private var tailAtEnd = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            VStack(alignment: .leading, spacing: ChromeMetrics.HoverCard.spacing) {
                HStack(spacing: ChromeMetrics.HoverCard.titleSpacing) {
                    Text(content.position)
                        .font(ChromeType.hoverCardDetail)
                        .foregroundStyle(theme.textLabel)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(content.statusWord)
                        .font(ChromeType.hoverCardDetail)
                        .foregroundStyle(theme.agentStatusColor(content.status) ?? theme.textLabel)
                }
                Text(content.cwd)
                    .font(ChromeType.hoverCardDetail)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                // Until the read lands there is no output to set apart, so the
                // rule waits for it too, and a pane with nothing on screen is
                // offered no copy of it.
                if let tail, let copy = PaneHoverCardCopy.text(of: tail) {
                    Rectangle()
                        .fill(theme.rule)
                        .frame(height: ChromeMetrics.ruleWidth)
                    tailLines(tail)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HoverCardCopyButton(theme: theme, text: copy)
                    }
                }
            }
            .padding(.vertical, ChromeMetrics.HoverCard.verticalPadding)
            .padding(.horizontal, ChromeMetrics.HoverCard.horizontalPadding)
        }
        .frame(width: ChromeMetrics.HoverCard.width, alignment: .leading)
        .background(theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.HoverCard.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.HoverCard.cornerRadius)
                .strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth)
        )
        // A container, not one combined element: the card holds controls, and
        // combining would fold them into the card's own text and leave nothing
        // to press.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.grid.hoverCard")
    }

    /// The card's handle, in the roles a thumbnail's own handle strip uses, so
    /// the card reads as that pane's window rather than a tooltip.
    private var bar: some View {
        HStack(spacing: ChromeMetrics.HoverCard.barSpacing) {
            StatusDot(status: content.status, theme: theme, size: ChromeMetrics.HoverCard.statusDot)
            Text(content.title)
                .font(ChromeType.hoverCardTitle)
                .foregroundStyle(theme.tabStripTitle)
                .lineLimit(1)
            Spacer(minLength: ChromeMetrics.HoverCard.titleSpacing)
            HoverCardBarButton(
                theme: theme, symbol: "arrow.up.forward.square", label: "Open pane",
                identifier: "flock.grid.hoverCard.open", action: open
            )
            HoverCardBarButton(
                theme: theme, symbol: "xmark", label: nil,
                identifier: "flock.grid.hoverCard.close", action: close
            )
            .accessibilityLabel("Close preview")
        }
        .padding(.leading, ChromeMetrics.HoverCard.horizontalPadding)
        .padding(.trailing, ChromeMetrics.HoverCard.barTrailingPadding)
        .frame(height: ChromeMetrics.HoverCard.barHeight)
        .frame(maxWidth: .infinity)
        .background(theme.tabStripFill)
    }

    /// The pane's own last lines, in the terminal face, wrapped rather than
    /// clipped: a pane is usually wider than the card. Wrapping makes the
    /// output's height depend on its line lengths, so it scrolls past a cap
    /// and opens on its newest lines, as the terminal itself would.
    private func tailLines(_ tail: PaneTail) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: ChromeMetrics.HoverCard.tailLineSpacing) {
                ForEach(Array(tail.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(ChromeType.hoverCardTail)
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tailHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollPosition($tailScroll)
        // Wrapped lines settle their height a pass after the first layout,
        // which leaves an anchor taken then short of the end, and a scroll to
        // the bottom edge lands a few points short of it too. So the end is
        // computed from the scroll view's own geometry and followed only
        // while the reader is at it, so new output never yanks them away from
        // what they scrolled to.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.containerSize.height } action: { _, end in
            guard followsTail else { return }
            // Snapped, never animated: the card's own open animation would
            // otherwise carry the scroll, leaving it short while it runs.
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) { tailScroll.scrollTo(y: max(0, end)) }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 1
        } action: { _, atEnd in
            tailAtEnd = atEnd
        }
        // Only the reader's own scroll decides whether the tail is followed:
        // content growing under a scroll that already ran also leaves the view
        // short of the end for a moment, and that is not the reader leaving it.
        .onScrollPhaseChange { old, new in
            if new == .interacting {
                followsTail = false
            } else if new == .idle, old == .interacting || old == .decelerating {
                followsTail = tailAtEnd
            }
        }
        // Sized to the output up to the cap, so a short tail leaves no gap
        // above the copy action.
        .frame(height: min(tailHeight, ChromeMetrics.HoverCard.tailMaxHeight))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flock.grid.hoverCard.tail")
    }
}

/// A control in the card's bar: a symbol, and a word when the symbol alone
/// would not say what it does.
private struct HoverCardBarButton: View {
    let theme: Theme
    let symbol: String
    let label: String?
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.HoverCard.copySpacing) {
                Image(systemName: symbol)
                    .font(ChromeType.hoverCardCopySymbol)
                if let label {
                    Text(label)
                        .font(ChromeType.hoverCardCopy)
                }
            }
            .foregroundStyle(theme.tabStripTitle.opacity(isHovering ? 1 : ChromeMetrics.HoverCard.barControlRestOpacity))
            .padding(.horizontal, ChromeMetrics.HoverCard.copyHorizontalPadding)
            .padding(.vertical, ChromeMetrics.HoverCard.copyVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.HoverCard.copyCornerRadius)
                    .fill(theme.chrome)
                    .opacity(isHovering ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(identifier)
    }
}

/// Puts the tail the card is showing on the pasteboard, and says so where the
/// pointer already is. It confirms in place rather than through the window's
/// toast: the grid covers the window, and a whisper somewhere else is a
/// confirmation for a copy nobody watched.
private struct HoverCardCopyButton: View {
    let theme: Theme
    let text: String

    @State private var isHovering = false
    @State private var confirming = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            confirming = true
        } label: {
            HStack(spacing: ChromeMetrics.HoverCard.copySpacing) {
                Image(systemName: confirming ? "checkmark" : "doc.on.doc")
                    .font(ChromeType.hoverCardCopySymbol)
                Text(confirming ? PaneHoverCardCopy.confirmation : PaneHoverCardCopy.label)
                    .font(ChromeType.hoverCardCopy)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, ChromeMetrics.HoverCard.copyHorizontalPadding)
            .padding(.vertical, ChromeMetrics.HoverCard.copyVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.HoverCard.copyCornerRadius)
                    .fill(theme.selection)
                    .opacity(isHovering ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("flock.grid.hoverCard.copy")
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: PaneHoverCardCopy.confirmationDuration)
            guard !Task.isCancelled else { return }
            confirming = false
        }
    }

    private var foreground: Color {
        if confirming { return theme.green }
        return isHovering ? theme.textStrong : theme.textLabel
    }
}
