import PaddockCore
import SwiftUI

/// Every workspace at once, one card each, its tabs drawn as their split
/// layouts in miniature. It stands in for the rail, strip and canvas while
/// shown. Thumbnails come from the layout snapshots and cached exports only:
/// the grid never attaches a pane, since attaching sizes the real one.
struct AllWorkspacesGrid: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag
    @State private var scrollPosition = ScrollPosition()

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.rule)
                .frame(height: ChromeMetrics.ruleWidth)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: ChromeMetrics.Grid.cardGap) {
                    ForEach(Array(GridCardLayout.cardRows(workspaces).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: ChromeMetrics.Grid.cardGap) {
                            ForEach(row, id: \.workspaceID) { workspace in
                                WorkspaceCard(theme: theme, viewModel: viewModel, workspace: workspace)
                            }
                            if row.count < GridCardLayout.columns {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                            }
                        }
                        // Cards sharing a row share the taller one's height.
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ChromeMetrics.Grid.canvasPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .coordinateSpace(.named(DragSpace.gridContent))
                .reportsDragFrame { drag.setGridContentOrigin($0.origin) }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollPosition($scrollPosition)
            .reportsScrollExtent(.vertical) { drag.setGridScroll(offset: $0, maximumOffset: $1) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .boundedBackground(theme.canvas)
            .overlay(alignment: .topLeading) { GridHoverCard(theme: theme, viewModel: viewModel) }
            .reportsDragFrame { drag.gridViewport = $0 }
            .onAppear { drag.gridScroller = { y in scrollPosition.scrollTo(y: y) } }
        }
        .boundedBackground(theme.chrome)
        .onAppear { drag.setGridOrder(itemOrder) }
        .onChange(of: itemOrder) { _, order in drag.setGridOrder(order) }
        .onChange(of: workspaces.map(\.workspaceID)) { _, ids in drag.retainGridCards(ids) }
    }

    private var header: some View {
        HStack(spacing: ChromeMetrics.Grid.headerSpacing) {
            Text("All workspaces")
                .font(ChromeType.gridTitle)
                .foregroundStyle(theme.textStrong)
            Text(workspaces.count == 1 ? "1 workspace" : "\(workspaces.count) workspaces")
                .font(ChromeType.gridCount)
                .foregroundStyle(theme.textLabel)
            Spacer(minLength: 0)
            Text("esc to return")
                .font(ChromeType.gridHint)
                .foregroundStyle(theme.textLabel)
        }
        .padding(.horizontal, ChromeMetrics.Grid.headerHorizontalPadding)
        .frame(height: ChromeMetrics.Grid.headerHeight)
        .background(WindowDragExclusion())
    }

    /// The items a drop can hit, in grid order: what turns their frames back
    /// into a list and drops the frame of an item no longer shown. The
    /// placeholder and the tile that stands in for it are both tracked as
    /// `.newTab`, since what that id names is the rect the created tab lands
    /// in, whichever cell is drawing it.
    private var itemOrder: [GridItemID] {
        workspaces.flatMap { workspace in
            let expanded = drag.expandedGridCards.contains(workspace.workspaceID)
            let tabs = (viewModel.model?.tabs[workspace.workspaceID] ?? []).map(\.tabID)
            let preview = CardDropPreview(workspace: workspace.workspaceID, drag: drag, model: viewModel.model)
            let cells = preview.cells(of: tabs, expanded: expanded)
            let tileCarriesIt = preview.tileCarriesTheDrop(of: tabs, expanded: expanded)
            return [.card(workspace.workspaceID)]
                + (tileCarriesIt ? [.newTab(workspace.workspaceID)] : [])
                + cells.map { cell -> GridItemID in
                    switch cell {
                    case .tab(let id): .tab(id)
                    case .moreTabs, .collapse: .tile(workspace.workspaceID)
                    case .newTab: .newTab(workspace.workspaceID)
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
    func cells(of tabs: [TabID], expanded: Bool) -> [GridCell] {
        GridCardLayout.cells(tabs: tabs, expanded: expanded, newTab: takesTheDrop, closing: closingTab)
    }

    /// Whether the card's trailing tile carries the preview instead, which is
    /// what a card that cannot draw a placeholder has to say the drop with.
    func tileCarriesTheDrop(of tabs: [TabID], expanded: Bool) -> Bool {
        takesTheDrop && GridCardLayout.tilePreviewsTheDrop(
            tabs: GridCardLayout.surviving(tabs, closing: closingTab).count, expanded: expanded
        )
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

private struct WorkspaceCard: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let workspace: WorkspaceRecord

    @Environment(DragCoordinator.self) private var drag

    var body: some View {
        let tabs = viewModel.model?.tabs[workspace.workspaceID] ?? []
        let rows = GridCardLayout.rows(
            preview.cells(of: tabs.map(\.tabID), expanded: drag.expandedGridCards.contains(workspace.workspaceID))
        )
        // Read once per card rather than per cell: only the card a reorder is
        // over, and only while that reorder commits, has any to report.
        let displacements = reorder.displacements
        VStack(alignment: .leading, spacing: ChromeMetrics.Grid.cardSpacing) {
            header(tabCount: tabs.count)
            VStack(alignment: .leading, spacing: ChromeMetrics.Grid.tabGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    // Every row keeps all its slots, so a short row's tabs are
                    // as wide as a full row's.
                    HStack(alignment: .top, spacing: ChromeMetrics.Grid.tabGap) {
                        ForEach(0..<GridCardLayout.tabsPerRow, id: \.self) { slot in
                            if slot < row.count {
                                cell(row[slot], tabs: tabs, displacements: displacements)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, ChromeMetrics.Grid.cardVerticalPadding)
        .padding(.horizontal, ChromeMetrics.Grid.cardHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.cardCornerRadius))
        .overlay {
            DropWash(theme: theme, isTargeted: takesTheDrop, cornerRadius: ChromeMetrics.Grid.cardCornerRadius)
        }
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.cardCornerRadius)
                .strokeBorder(isTargeted(tabs) ? theme.accent : theme.paneBorder, lineWidth: ChromeMetrics.ruleWidth)
        )
        .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: isTargeted(tabs))
        .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .card(workspace.workspaceID)) }
        .accessibilityIdentifier("paddock.grid.workspace.\(workspace.workspaceID.rawValue)")
    }

    /// herdr's focused workspace carries the rail's accent bar; the header
    /// keeps the row height either way so cards in a row line up.
    private func header(tabCount: Int) -> some View {
        HStack(spacing: ChromeMetrics.Grid.cardHeaderSpacing) {
            if workspace.workspaceID == viewModel.model?.focusedWorkspaceID {
                RoundedRectangle(cornerRadius: ChromeMetrics.WorkspaceRow.indicatorSize.width / 2)
                    .fill(theme.accent)
                    .frame(width: ChromeMetrics.WorkspaceRow.indicatorSize.width, height: ChromeMetrics.WorkspaceRow.indicatorSize.height)
            }
            Text(workspace.label)
                .font(ChromeType.gridCardName)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
            Text(tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
                .font(ChromeType.gridCardMeta)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let color = theme.agentStatusColor(workspace.agentStatus) {
                Circle()
                    .fill(color)
                    .frame(width: ChromeMetrics.Grid.cardStatusDot, height: ChromeMetrics.Grid.cardStatusDot)
            }
        }
        .frame(height: ChromeMetrics.WorkspaceRow.contentHeight)
    }

    @ViewBuilder
    private func cell(_ cell: GridCell, tabs: [TabRecord], displacements: [TabID: CGSize]) -> some View {
        switch cell {
        case .tab(let id):
            if let tab = tabs.first(where: { $0.tabID == id }) {
                TabThumbnail(
                    theme: theme, viewModel: viewModel, tab: tab,
                    isTargeted: MiniPaneLayout.targetedTab(of: drag.target, model: viewModel.model) == id,
                    displacement: displacements[id] ?? .zero
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
        case .moreTabs(let hidden):
            tile(title: "+\(hidden)", label: "more tabs", tabs: tabs)
        case .collapse:
            tile(title: "fewer", label: "fewer tabs", tabs: tabs)
        case .newTab:
            NewTabPlaceholder(theme: theme, workspace: workspace.workspaceID)
        }
    }

    /// Either tile a card can show. Neither takes a drop, so both refuse one
    /// visibly rather than letting the card behind them make a tab.
    ///
    /// The tile also carries the card's OWN drop preview when the card cannot
    /// draw a placeholder: its hidden count is the only thing such a drop
    /// visibly changes. It then reports its frame as the new tab's too, since
    /// that cell is where the created tab lands and so where a committed drop
    /// has to settle.
    private func tile(title: String, label: String, tabs: [TabRecord]) -> some View {
        let carriesTheCardsDrop = carriesTheCardsDrop(tabs: tabs)
        return GridTile(
            theme: theme, title: title, label: label,
            isTargeted: drag.target == .moreTabs(workspace.workspaceID) || carriesTheCardsDrop,
            reportsAs: .tile(workspace.workspaceID),
            alsoReportsAs: carriesTheCardsDrop ? .newTab(workspace.workspaceID) : nil
        ) {
            drag.toggleGridCard(workspace.workspaceID)
        }
    }

    private func carriesTheCardsDrop(tabs: [TabRecord]) -> Bool {
        preview.tileCarriesTheDrop(
            of: tabs.map(\.tabID), expanded: drag.expandedGridCards.contains(workspace.workspaceID)
        )
    }

    /// The accent outline: on whichever card owns the target, whether that is
    /// one of its thumbnails, its tile, a reorder among its own cells, or the
    /// card itself.
    private func isTargeted(_ tabs: [TabRecord]) -> Bool {
        switch drag.target {
        case .tabThumbnail?, .paneEdge?, .paneInterior?:
            let targeted = MiniPaneLayout.targetedTab(of: drag.target, model: viewModel.model)
            return tabs.contains { $0.tabID == targeted }
        case .moreTabs(let id)?: return id == workspace.workspaceID
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

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            GeometryReader { proxy in
                miniPanes(size: proxy.size)
            }
        }
        .frame(height: ChromeMetrics.Grid.thumbnailHeight)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .overlay { DropWash(theme: theme, isTargeted: isTargeted) }
        .contentShape(Rectangle())
        // Selected before the grid closes, so the window never draws the
        // previously selected tab in between.
        .onTapGesture {
            viewModel.select(tab: tab.tabID)
            drag.closeGrid()
            Task { await viewModel.jumpToHerdr(tab: tab.tabID) }
        }
        .accessibilityIdentifier("paddock.grid.tab.\(tab.tabID.rawValue)")
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

    private var titleStrip: some View {
        TabHandleStrip(
            theme: theme, title: tab.label, status: tab.agentStatus,
            isFocusedTab: tab.tabID == viewModel.model?.focusedTabID
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
                        title: tab.label, symbol: "rectangle.stack",
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
            title: tab.label, status: tab.agentStatus,
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
                    MiniPane(theme: theme, title: pane.displayTitle, status: pane.agentStatus)
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.minX, y: placed.frame.minY)
                        .opacity(drag.isDragging(pane: pane.paneID) ? DragVisuals.originOpacity : 1)
                        .gesture(paneDrag(pane, box: placed.frame))
                        // In the drag space, where the card is placed: a
                        // scroll or reflow under a still pointer leaves the
                        // pointer, and so the card, where it is.
                        .onContinuousHover(coordinateSpace: DragSpace.coordinateSpace) { phase in
                            switch phase {
                            case .active(let pointer):
                                drag.gridHoverMoved(pane: pane.paneID, pointer: pointer)
                                GridCursor.hover(true, dragInFlight: drag.holdsGrabCursor)
                            case .ended:
                                drag.gridHoverEnded(pane: pane.paneID)
                                GridCursor.hover(false, dragInFlight: drag.holdsGrabCursor)
                            }
                        }
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

/// A tab's handle: a band across the top of its thumbnail carrying the title
/// and status dot. Shared with the drag proxy, which draws a whole tab as a
/// miniature of its own thumbnail and has to use the same roles.
///
/// Filled with `paneBorder` rather than a lighter step: the thumbnail's body
/// is `canvas`, and the roles between the two (`tabRest`, `rule`) land within
/// about 1.1:1 of it in every builtin theme, which reads as the same surface.
/// `paneBorder` is the nearest role that separates (1.49:1 at worst, on
/// Catppuccin Latte) and it is already the role a box edge takes, so a solid
/// band of it reads as structure.
///
/// The title is `textStrong` whether or not the tab is focused. `textDim` on
/// this band falls under 4.5:1 in three of the seventeen builtin themes
/// (nord, one-dark, dracula), and no role that separates from the body keeps
/// it above AA everywhere; `textStrong` clears at 5.07:1 at worst. Focus is
/// carried by the accent bar at the leading edge, which is the rail's own
/// mark for its focused workspace, and by the weight
/// `ChromeType.gridTabLabel(selected:)` sets; the status dot encodes agent
/// status and nothing else. The bar's slot is present on every strip, clear
/// where there is nothing to mark, so titles stay aligned across a card.
struct TabHandleStrip: View {
    let theme: Theme
    let title: String
    let status: AgentStatus
    let isFocusedTab: Bool

    var body: some View {
        HStack(spacing: ChromeMetrics.Grid.tabStripSpacing) {
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.tabStripIndicatorSize.width / 2)
                .fill(isFocusedTab ? theme.accent : .clear)
                .frame(
                    width: ChromeMetrics.Grid.tabStripIndicatorSize.width,
                    height: ChromeMetrics.Grid.tabStripIndicatorSize.height
                )
            Text(title)
                .font(ChromeType.gridTabLabel(selected: isFocusedTab))
                .foregroundStyle(theme.tabStripTitle)
                .lineLimit(1)
            Spacer(minLength: 0)
            StatusDot(status: status, theme: theme, size: ChromeMetrics.Grid.labelStatusDot)
        }
        .padding(.horizontal, ChromeMetrics.Grid.tabStripHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ChromeMetrics.Grid.tabStripHeight)
        .background(theme.tabStripFill)
    }
}

/// A pane in miniature: its title and status dot, nothing else. Takes the two
/// values rather than a `PaneRecord` so the drag proxy, which carries a
/// snapshot of what was picked up, can draw the same box.
struct MiniPane: View {
    let theme: Theme
    let title: String
    let status: AgentStatus

    var body: some View {
        HStack(spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
            StatusDot(status: status, theme: theme, size: ChromeMetrics.Grid.miniPaneStatusDot)
            Text(title)
                .font(ChromeType.gridMiniPaneTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
        }
        .padding(.vertical, ChromeMetrics.Grid.miniPaneVerticalPadding)
        .padding(.horizontal, ChromeMetrics.Grid.miniPaneHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.Grid.miniPaneCornerRadius)
                .strokeBorder(theme.paneBorder, lineWidth: ChromeMetrics.ruleWidth)
        )
        .contentShape(Rectangle())
    }
}

/// The +N tile and the collapse tile: a thumbnail-sized block with a count or
/// word over its label. Both lines live inside the block, so a tile is exactly
/// as tall as the thumbnails beside it.
private struct GridTile: View {
    let theme: Theme
    let title: String
    let label: String
    let isTargeted: Bool
    let reportsAs: GridItemID
    /// A second id for the same rect, for when this tile is standing in for
    /// the tab a card drop will create: that is the rect the drop lands in.
    var alsoReportsAs: GridItemID?
    let action: () -> Void

    @Environment(DragCoordinator.self) private var drag

    var body: some View {
        VStack(spacing: ChromeMetrics.Grid.tabLabelGap) {
            Text(title)
                .font(ChromeType.gridTileTitle)
                .foregroundStyle(theme.textDim)
            Text(label)
                .font(ChromeType.gridTileLabel)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ChromeMetrics.Grid.thumbnailHeight)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .overlay { DropWash(theme: theme, isTargeted: isTargeted) }
        .background {
            Color.clear.reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: reportsAs) }
        }
        // A SECOND reporter rather than a second call inside the first: a
        // frame report fires on appear and on a geometry change, and this
        // tile's geometry is exactly what does NOT change when it starts
        // standing in for a new tab (that is why it carries the preview at
        // all). Inserting a view when the id appears is what makes its own
        // appear fire and publish the rect.
        .background {
            if let alsoReportsAs {
                Color.clear.reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: alsoReportsAs) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The tab a drop on this card's empty space is about to create, drawn in the
/// slot that tab will take. Its own cell comes from `GridCardLayout`, so the
/// card's rows place it exactly as they place a real thumbnail. It reports a
/// frame but is never a drop surface: the card behind it is what answers.
private struct NewTabPlaceholder: View {
    let theme: Theme
    let workspace: WorkspaceID

    @Environment(DragCoordinator.self) private var drag

    var body: some View {
        VStack(spacing: 0) {
            Text("new tab")
                .font(ChromeType.gridTabLabel(selected: false))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                // Past the slot a real strip keeps for its focus bar, so the
                // placeholder's title lines up with the titles beside it.
                .padding(.leading, ChromeMetrics.Grid.tabStripIndicatorSize.width + ChromeMetrics.Grid.tabStripSpacing)
                .padding(.horizontal, ChromeMetrics.Grid.tabStripHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: ChromeMetrics.Grid.tabStripHeight)
                .background(theme.accent.opacity(DragVisuals.dropWashOpacity))
            Color.clear
        }
        .frame(maxWidth: .infinity)
        .frame(height: ChromeMetrics.Grid.thumbnailHeight)
        // The wash alone, never a stroke, which is how the canvas previews a
        // drop; the strip band takes a second coat of it so the tab's own
        // handle shape still reads inside an otherwise empty slot.
        .background(theme.accent.opacity(DragVisuals.dropWashOpacity), in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
        .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .newTab(workspace)) }
        .allowsHitTesting(false)
        .accessibilityIdentifier("paddock.grid.newTab.\(workspace.rawValue)")
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
/// never clipped by the card or the row below it, and only it re-renders as
/// the pointer moves.
private struct GridHoverCard: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag
    @State private var size = CGSize(width: ChromeMetrics.HoverCard.width, height: ChromeMetrics.HoverCard.estimatedHeight)

    var body: some View {
        if let hover = drag.gridHoverCard,
           let viewport = drag.gridViewport,
           let model = viewModel.model,
           let pane = model.panes[hover.pane],
           let content = PaneHoverCardContent.make(
               pane: hover.pane, model: model, exported: viewModel.exportedLayout(for: pane.tabID), homeDirectory: NSHomeDirectory()
           ) {
            let origin = HoverCardPlacement.origin(
                pointer: CGPoint(x: hover.pointer.x - viewport.minX, y: hover.pointer.y - viewport.minY),
                card: size, container: CGRect(origin: .zero, size: viewport.size), offset: ChromeMetrics.HoverCard.pointerOffset
            )
            PaneHoverCardView(theme: theme, content: content, lastLine: viewModel.lastLine(for: pane))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)
        }
    }
}

private struct PaneHoverCardView: View {
    let theme: Theme
    let content: PaneHoverCardContent
    let lastLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.HoverCard.spacing) {
            HStack(spacing: ChromeMetrics.HoverCard.titleSpacing) {
                StatusDot(status: content.status, theme: theme, size: ChromeMetrics.HoverCard.statusDot)
                Text(content.title)
                    .font(ChromeType.hoverCardTitle)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(content.statusWord)
                    .font(ChromeType.hoverCardDetail)
                    .foregroundStyle(theme.agentStatusColor(content.status) ?? theme.textLabel)
            }
            Text(content.position)
                .font(ChromeType.hoverCardDetail)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
            Text(content.cwd)
                .font(ChromeType.hoverCardDetail)
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .truncationMode(.head)
            // Until the read lands there is no line to set apart, so the rule
            // waits for it too.
            if let lastLine, !lastLine.isEmpty {
                Rectangle()
                    .fill(theme.rule)
                    .frame(height: ChromeMetrics.ruleWidth)
                Text(lastLine)
                    .font(ChromeType.hoverCardLastLine)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, ChromeMetrics.HoverCard.verticalPadding)
        .padding(.horizontal, ChromeMetrics.HoverCard.horizontalPadding)
        .frame(width: ChromeMetrics.HoverCard.width, alignment: .leading)
        .background(theme.chrome, in: RoundedRectangle(cornerRadius: ChromeMetrics.HoverCard.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.HoverCard.cornerRadius)
                .strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth)
        )
    }
}
