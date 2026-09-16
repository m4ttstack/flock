import CoreGraphics

/// One slot in a workspace card of the All Workspaces grid.
public enum GridCell: Hashable, Sendable {
    case tab(TabID)
    /// Stands in for the tabs a resting card does not show.
    case moreTabs(hidden: Int)
    /// Ends an expanded card and folds it back to rest.
    case collapse
    /// The tab a drop on this card's empty space is about to create, drawn
    /// in the slot that tab will take.
    case newTab
}

extension GridCell {
    /// The trailing control a card can end with. It is not a tab, so it is
    /// never the slot a new tab lands in.
    var isTile: Bool {
        switch self {
        case .moreTabs, .collapse: true
        case .tab, .newTab: false
        }
    }
}

/// Which tabs a workspace card shows and how they wrap.
///
/// How many thumbnails a row holds is the window's answer, not a constant:
/// every function that shapes a card takes `perRow` so the cells, the rows,
/// the tile and the placeholder are all laid out against the same count.
public enum GridCardLayout {
    /// The fewest slots a card row is ever divided into. A window too narrow
    /// to give that many slots the full thumbnail width shrinks them instead,
    /// which is the shape the grid has always had; only a wider window buys
    /// slots.
    public static let minimumTabsPerRow = 4
    public static let columns = 2

    /// How many thumbnails one row of `rowWidth` holds: as many as fit with
    /// none of them passing `maximumWidth`, never fewer than
    /// `minimumTabsPerRow`. Widening the window buys slots rather than
    /// stretching every thumbnail.
    public static func tabsPerRow(rowWidth: CGFloat, maximumWidth: CGFloat, gap: CGFloat) -> Int {
        guard rowWidth > 0, maximumWidth > 0 else { return minimumTabsPerRow }
        return max(minimumTabsPerRow, Int(((rowWidth + gap) / (maximumWidth + gap)).rounded(.down)))
    }

    /// The width one card draws its thumbnails across, given the grid's own
    /// content width. The cards split that width evenly and each spends its
    /// horizontal padding on both sides, so this is the only arithmetic
    /// between what the grid measures and what a row is actually given.
    public static func rowWidth(gridContentWidth: CGFloat, cardGap: CGFloat, cardPadding: CGFloat) -> CGFloat {
        let card = (gridContentWidth - cardGap * CGFloat(columns - 1)) / CGFloat(columns)
        return max(0, card - cardPadding * 2)
    }

    /// A resting card spends its last slot on the +N tile.
    public static func restingTabCount(perRow: Int) -> Int { perRow - 1 }

    /// A workspace whose tabs fit one row shows every tab and has nothing to
    /// expand.
    ///
    /// `newTab` inserts the drop placeholder where the tab itself will be
    /// ordered, which is BEFORE the trailing tile, never after it: a tile
    /// always ends the list, so the slot past it is one no tab can reach.
    ///
    /// `closing` is a tab of this card the same drop takes away (the pane
    /// being dropped is the last one in it), so the card lays the preview out
    /// without it and the created tab takes the slot it leaves. A card that
    /// draws no placeholder is left exactly as it stands instead, since a
    /// hover that reshuffles cells it cannot explain is worse than one that
    /// shows nothing.
    ///
    /// The placeholder is shown at all only while the preview's own rows are
    /// rows the drop leaves behind (`previewKeepsItsRows`). A card that would
    /// gain a row on hover and lose it again on drop shows nothing, and its
    /// accent outline marks it the way it marks every other card-level drop
    /// target.
    public static func cells(tabs: [TabID], expanded: Bool, newTab: Bool = false, closing: TabID? = nil, perRow: Int) -> [GridCell] {
        let surviving = surviving(tabs, closing: closing)
        guard newTab, previewKeepsItsRows(tabs: surviving.count, expanded: expanded, perRow: perRow) else {
            return settled(tabs: tabs, expanded: expanded, perRow: perRow)
        }
        // The shape the card takes once the drop lands, with the tab it
        // creates drawn as the placeholder. Laid out over the post-drop list
        // rather than over the surviving tabs alone, so the trailing tile is
        // the one the drop leaves: five expanded tabs losing one still end
        // the drop with five and the collapse tile they need.
        return settled(tabs: surviving + [createdTab], expanded: expanded, perRow: perRow)
            .map { $0 == .tab(createdTab) ? .newTab : $0 }
    }

    /// Stands in for the tab a previewed drop creates while the post-drop
    /// shape is laid out. Replaced by `.newTab` before the cells leave
    /// `cells`, so it reaches no view and no frame report; the id shape is
    /// one herdr never issues.
    private static let createdTab = TabID(rawValue: "paddock.preview.created-tab")

    /// The tabs a card is left holding once the drop lands: a pane leaving
    /// the last pane of its tab takes that tab with it, and herdr appends the
    /// tab it creates, so the created tab takes the slot the closing one
    /// vacates rather than the slot after it.
    public static func surviving(_ tabs: [TabID], closing: TabID?) -> [TabID] {
        guard let closing else { return tabs }
        return tabs.filter { $0 != closing }
    }

    /// Whether the card's trailing tile carries the drop preview in place of
    /// a placeholder. A resting card over its cap draws no new tab at all,
    /// and the tile is the one cell the drop visibly changes: its hidden
    /// count grows by one. A card with no tile has nothing to carry it (the
    /// only slot that changes is a real tab's, whose wash already means that
    /// tab takes the drop), so it previews nothing.
    public static func tilePreviewsTheDrop(tabs: Int, expanded: Bool, perRow: Int) -> Bool {
        !previewKeepsItsRows(tabs: tabs, expanded: expanded, perRow: perRow) && hasTile(tabs: tabs, perRow: perRow)
    }

    /// A card draws a tile only once its tabs outrun a single row: `+N` at
    /// rest, `fewer` once expanded.
    static func hasTile(tabs: Int, perRow: Int) -> Bool { tabs > perRow }

    /// The gap a point names among cells that wrap: rows top to bottom, cells
    /// left to right inside a row. A cell comes before the point when the
    /// point is past that cell's row entirely, or in its row and past its
    /// centre, which is the strip's own centre-crossing rule applied one row
    /// at a time. The count of such cells is the insert index, so a point
    /// over a cell's own body still names the gap on one side of it.
    ///
    /// `cells` are the card's TAB cells in the order it draws them, which a
    /// resting card takes from the front of its workspace's tab list, so the
    /// answer is an index into that list too.
    public static func insertIndex(at point: CGPoint, cells: [CGRect]) -> Int {
        cells.filter { cell in
            if point.y > cell.maxY { return true }
            if point.y < cell.minY { return false }
            return point.x > cell.midX
        }.count
    }

    /// A RESTING card over its cap redraws to the same single row however
    /// many tabs it gains, so a placeholder there opens a row that collapses
    /// again the moment the drop lands, whichever slot it takes. An EXPANDED
    /// card draws every tab, so a row it gains on hover is one it keeps.
    private static func previewKeepsItsRows(tabs: Int, expanded: Bool, perRow: Int) -> Bool {
        rowCount(settledCount(tabs: tabs, expanded: expanded, perRow: perRow) + 1, perRow: perRow)
            <= rowCount(settledCount(tabs: tabs + 1, expanded: expanded, perRow: perRow), perRow: perRow)
    }

    /// `settled(tabs:expanded:perRow:).count` without building the cells, so
    /// the shape a card takes AFTER a drop can be weighed against the one it
    /// has now. The two must agree for every count.
    static func settledCount(tabs: Int, expanded: Bool, perRow: Int) -> Int {
        guard tabs > perRow else { return tabs }
        return expanded ? tabs + 1 : perRow
    }

    static func rowCount(_ cells: Int, perRow: Int) -> Int {
        (cells + perRow - 1) / perRow
    }

    private static func settled(tabs: [TabID], expanded: Bool, perRow: Int) -> [GridCell] {
        guard tabs.count > perRow else { return tabs.map(GridCell.tab) }
        guard expanded else {
            let shown = restingTabCount(perRow: perRow)
            return tabs.prefix(shown).map(GridCell.tab) + [.moreTabs(hidden: tabs.count - shown)]
        }
        return tabs.map(GridCell.tab) + [.collapse]
    }

    public static func rows(tabs: [TabID], expanded: Bool, newTab: Bool = false, perRow: Int) -> [[GridCell]] {
        rows(cells(tabs: tabs, expanded: expanded, newTab: newTab, perRow: perRow), perRow: perRow)
    }

    /// Cells a card has already decided on, wrapped into its rows.
    public static func rows(_ cells: [GridCell], perRow: Int) -> [[GridCell]] {
        chunked(cells, by: perRow)
    }

    /// Cards in rail order, `columns` to a row.
    public static func cardRows<Item>(_ items: [Item]) -> [[Item]] {
        chunked(items, by: columns)
    }

    static func chunked<Item>(_ items: [Item], by size: Int) -> [[Item]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

/// The grid's own state: whether it covers the window, which cards are
/// expanded, and which mini pane the pointer rests on.
public struct AllWorkspacesGridState: Equatable, Sendable {
    public struct Hover: Equatable, Sendable {
        public let pane: PaneID
        /// The pointer, in the drag space.
        public let pointer: CGPoint

        public init(pane: PaneID, pointer: CGPoint) {
            self.pane = pane
            self.pointer = pointer
        }
    }

    /// How long the pointer must rest on one pane before its card shows, so
    /// a sweep across the grid neither flickers cards nor reads every pane
    /// it crosses.
    public static let hoverIntentDelay: Duration = .milliseconds(200)

    public private(set) var isShown = false
    public private(set) var expanded: Set<WorkspaceID> = []
    /// The pane whose card is showing.
    public private(set) var hover: Hover?
    /// The pane waiting out the intent delay.
    public private(set) var pendingHover: Hover?

    public init() {}

    public mutating func open() {
        isShown = true
    }

    /// A grid opened again starts at rest.
    public mutating func close() {
        isShown = false
        expanded.removeAll()
        hover = nil
        pendingHover = nil
    }

    public mutating func toggle() {
        if isShown {
            close()
        } else {
            open()
        }
    }

    public mutating func toggleExpanded(_ workspace: WorkspaceID) {
        if expanded.contains(workspace) {
            expanded.remove(workspace)
        } else {
            expanded.insert(workspace)
        }
    }

    /// Forgets every workspace `order` no longer carries.
    public mutating func retain(_ order: [WorkspaceID]) {
        expanded.formIntersection(Set(order))
    }

    /// Every pointer report over a mini pane. Moving within the pane the card
    /// or the wait already belongs to only moves the pointer; any other pane
    /// hides the card and starts a new wait. True when a wait starts, which
    /// the caller times out through `hoverIntentElapsed`.
    @discardableResult
    public mutating func hoverMoved(pane: PaneID, pointer: CGPoint) -> Bool {
        let report = Hover(pane: pane, pointer: pointer)
        if hover?.pane == pane {
            hover = report
            return false
        }
        if pendingHover?.pane == pane {
            pendingHover = report
            return false
        }
        hover = nil
        pendingHover = report
        return true
    }

    /// A wait that has since moved to another pane, or ended, shows nothing.
    public mutating func hoverIntentElapsed(pane: PaneID) {
        guard let pendingHover, pendingHover.pane == pane else { return }
        hover = pendingHover
        self.pendingHover = nil
    }

    /// Only the pane still hovered or waited on clears: moving onto a
    /// neighbor can report the neighbor's entry before this pane's exit.
    public mutating func hoverEnded(pane: PaneID) {
        if hover?.pane == pane {
            hover = nil
        }
        if pendingHover?.pane == pane {
            pendingHover = nil
        }
    }

    /// Hover reports stop while the button is held, so whatever was hovered
    /// when a drag began is stale by the time it ends.
    public mutating func dragBegan() {
        hover = nil
        pendingHover = nil
    }

    /// Never while a drag is in flight, when the card would cover the
    /// thumbnails the drop is aimed at.
    public func hoverCard(dragInFlight: Bool) -> Hover? {
        dragInFlight ? nil : hover
    }

    /// What a fired dwell does to the grid: uncover the tabs a "+N" tile
    /// stands for, so one of them can take the drop. A grid drag stays in the
    /// grid, so no dwell hands the window back mid-drag.
    public mutating func springLoaded(_ target: DropTarget) {
        guard case .moreTabs(let workspace) = target, isShown else { return }
        expanded.insert(workspace)
    }
}

/// Who an Esc belongs to.
public enum EscapeRoute: Equatable, Sendable {
    case drag
    case grid
    case railSelection
    case focusedView

    /// A live drag owns Esc as its cancel. The grid covers the rail, so it
    /// outranks the rail's selection, and what is left reaches the focused
    /// terminal.
    public static func route(dragIdle: Bool, gridShown: Bool, railTakesEscape: Bool) -> EscapeRoute {
        guard dragIdle else { return .drag }
        if gridShown { return .grid }
        return railTakesEscape ? .railSelection : .focusedView
    }
}
