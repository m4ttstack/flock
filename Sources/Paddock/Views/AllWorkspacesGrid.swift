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
    /// into a list and drops the frame of an item no longer shown.
    private var itemOrder: [GridItemID] {
        workspaces.flatMap { workspace in
            let tabs = (viewModel.model?.tabs[workspace.workspaceID] ?? []).map(\.tabID)
            let cells = GridCardLayout.cells(tabs: tabs, expanded: drag.expandedGridCards.contains(workspace.workspaceID))
            return [.card(workspace.workspaceID)] + cells.compactMap { cell -> GridItemID? in
                switch cell {
                case .tab(let id): .tab(id)
                case .moreTabs: .moreTabs(workspace.workspaceID)
                case .collapse: nil
                }
            }
        }
    }
}

private struct WorkspaceCard: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let workspace: WorkspaceRecord

    @Environment(DragCoordinator.self) private var drag

    var body: some View {
        let tabs = viewModel.model?.tabs[workspace.workspaceID] ?? []
        let rows = GridCardLayout.rows(tabs: tabs.map(\.tabID), expanded: drag.expandedGridCards.contains(workspace.workspaceID))
        VStack(alignment: .leading, spacing: ChromeMetrics.Grid.cardSpacing) {
            header(tabCount: tabs.count)
            VStack(alignment: .leading, spacing: ChromeMetrics.Grid.tabGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    // Every row keeps all its slots, so a short row's tabs are
                    // as wide as a full row's.
                    HStack(alignment: .top, spacing: ChromeMetrics.Grid.tabGap) {
                        ForEach(0..<GridCardLayout.tabsPerRow, id: \.self) { slot in
                            if slot < row.count {
                                cell(row[slot], tabs: tabs)
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
    private func cell(_ cell: GridCell, tabs: [TabRecord]) -> some View {
        switch cell {
        case .tab(let id):
            if let tab = tabs.first(where: { $0.tabID == id }) {
                TabThumbnail(theme: theme, viewModel: viewModel, tab: tab, isTargeted: drag.target == .tabThumbnail(id))
            }
        case .moreTabs(let hidden):
            GridTile(
                theme: theme, title: "+\(hidden)", label: "more tabs",
                isTargeted: drag.target == .moreTabs(workspace.workspaceID), reportsAs: .moreTabs(workspace.workspaceID)
            ) {
                drag.toggleGridCard(workspace.workspaceID)
            }
        case .collapse:
            GridTile(theme: theme, title: "fewer", label: "fewer tabs", isTargeted: false, reportsAs: nil) {
                drag.toggleGridCard(workspace.workspaceID)
            }
        }
    }

    /// The accent outline: on whichever card owns the target, whether that is
    /// one of its thumbnails, its +N tile, or the card itself.
    private func isTargeted(_ tabs: [TabRecord]) -> Bool {
        switch drag.target {
        case .tabThumbnail(let id)?: tabs.contains { $0.tabID == id }
        case .moreTabs(let id)?: id == workspace.workspaceID
        default: takesTheDrop
        }
    }

    /// The card itself is the target: a drop lands in a new tab of this
    /// workspace, or migrates a whole tab into it.
    private var takesTheDrop: Bool {
        drag.target == .workspaceThumbnail(workspace.workspaceID)
    }
}

private struct TabThumbnail: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let tab: TabRecord
    let isTargeted: Bool

    @Environment(DragCoordinator.self) private var drag
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let isFocusedTab = tab.tabID == viewModel.model?.focusedTabID
        VStack(alignment: .leading, spacing: ChromeMetrics.Grid.tabLabelGap) {
            GeometryReader { proxy in
                miniPanes(size: proxy.size)
            }
            .frame(height: ChromeMetrics.Grid.thumbnailHeight)
            .background(theme.canvas, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
            .overlay { DropWash(theme: theme, isTargeted: isTargeted) }
            .reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: .tab(tab.tabID)) }
            .contentShape(Rectangle())
            // Selected before the grid closes, so the window never draws the
            // previously selected tab in between.
            .onTapGesture {
                viewModel.select(tab: tab.tabID)
                drag.closeGrid()
                Task { await viewModel.jumpToHerdr(tab: tab.tabID) }
            }
            .accessibilityIdentifier("paddock.grid.tab.\(tab.tabID.rawValue)")
            HStack(spacing: ChromeMetrics.Grid.labelDotGap) {
                Text(tab.label)
                    .font(ChromeType.gridTabLabel(selected: isFocusedTab))
                    .foregroundStyle(isFocusedTab ? theme.textStrong : theme.textDim)
                    .lineLimit(1)
                StatusDot(status: tab.agentStatus, theme: theme, size: ChromeMetrics.Grid.labelStatusDot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(drag.isDragging(tab: tab.tabID) ? DragVisuals.originOpacity : 1)
        // On the whole thumbnail, mini panes included, so a press anywhere a
        // mini pane does not cover drags the tab. A mini pane's own gesture
        // is a descendant's, so it takes the press where it sits.
        .gesture(tabDrag)
    }

    private var tabDrag: some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                drag.beginIfIdle(
                    .tab(tab.tabID),
                    ghost: DragCoordinator.Ghost(
                        title: tab.label,
                        symbol: "rectangle.stack",
                        originSize: drag.surfaces?.grid?.thumbnails.first { $0.id == tab.tabID }?.frame.size ?? .zero
                    ),
                    at: value.startLocation
                )
            }
    }

    /// A mini pane is a preview, never a surface, so the proxy carries the
    /// pane's title over the mini pane's own footprint.
    private func paneDrag(_ pane: PaneRecord, origin: CGSize) -> some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                drag.beginIfIdle(
                    .pane(pane.paneID),
                    ghost: DragCoordinator.Ghost(title: pane.displayTitle, symbol: "macwindow", originSize: origin),
                    at: value.startLocation
                )
            }
    }

    private func miniPanes(size: CGSize) -> some View {
        let model = viewModel.model
        let tabPanes = (model?.panes.values.filter { $0.tabID == tab.tabID } ?? [])
            .map(\.paneID)
            .sorted { $0.rawValue < $1.rawValue }
        let boxes = MiniPaneLayout.boxes(
            layout: model?.layouts[tab.tabID],
            exported: viewModel.exportedLayout(for: tab.tabID),
            fallbackPanes: tabPanes,
            size: size,
            padding: ChromeMetrics.Grid.thumbnailPadding,
            gap: ChromeMetrics.Grid.miniPaneGap,
            displayScale: displayScale > 0 ? displayScale : 2
        )
        return ZStack(alignment: .topLeading) {
            ForEach(boxes, id: \.pane) { placed in
                if let pane = model?.panes[placed.pane] {
                    MiniPane(theme: theme, pane: pane)
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.minX, y: placed.frame.minY)
                        .opacity(drag.isDragging(pane: pane.paneID) ? DragVisuals.originOpacity : 1)
                        .gesture(paneDrag(pane, origin: placed.frame.size))
                        // In the drag space, where the card is placed: a
                        // scroll or reflow under a still pointer leaves the
                        // pointer, and so the card, where it is.
                        .onContinuousHover(coordinateSpace: DragSpace.coordinateSpace) { phase in
                            switch phase {
                            case .active(let pointer): drag.gridHoverMoved(pane: pane.paneID, pointer: pointer)
                            case .ended: drag.gridHoverEnded(pane: pane.paneID)
                            }
                        }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// A pane in miniature: its title and status dot, nothing else.
private struct MiniPane: View {
    let theme: Theme
    let pane: PaneRecord

    var body: some View {
        HStack(spacing: ChromeMetrics.Grid.miniPaneTitleSpacing) {
            StatusDot(status: pane.agentStatus, theme: theme, size: ChromeMetrics.Grid.miniPaneStatusDot)
            Text(pane.displayTitle)
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
/// word, and a label where a tab's would be.
private struct GridTile: View {
    let theme: Theme
    let title: String
    let label: String
    let isTargeted: Bool
    /// Only a tile a drop can dwell on reports its frame.
    let reportsAs: GridItemID?
    let action: () -> Void

    @Environment(DragCoordinator.self) private var drag

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.Grid.tabLabelGap) {
            Text(title)
                .font(ChromeType.gridTileTitle)
                .foregroundStyle(theme.textDim)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.Grid.thumbnailHeight)
                .background(theme.canvas, in: RoundedRectangle(cornerRadius: ChromeMetrics.Grid.thumbnailCornerRadius))
                .overlay { DropWash(theme: theme, isTargeted: isTargeted) }
                .background {
                    if let reportsAs {
                        Color.clear.reportsFrame(in: DragSpace.gridContent) { drag.setGridItemFrame($0, for: reportsAs) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
            Text(label)
                .font(ChromeType.gridTileLabel)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
