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
    /// The trailing control a card can end with. It is not a tab, so a card
    /// only ever lands a drop on it when the tab that drop creates is one the
    /// card will not be drawing at all.
    public var isTile: Bool {
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
    public static let columns = 2

    /// How many thumbnails of `width` one row of `rowWidth` holds, never more
    /// than `cap`. A thumbnail is the same size at every window, so a wider
    /// window buys slots and a narrower one gives them up, and whatever is
    /// left over sits at the end of the row.
    ///
    /// Past `cap` the extra width buys nothing and the card wraps instead: a
    /// row of seven or more reads as a filmstrip rather than a card.
    ///
    /// Never zero: a row too narrow for even one thumbnail still draws one,
    /// overflowing its card rather than drawing a card whose tabs cannot be
    /// seen, reached or dropped on at all.
    public static func tabsPerRow(rowWidth: CGFloat, width: CGFloat, gap: CGFloat, cap: Int) -> Int {
        guard rowWidth > 0, width > 0 else { return 1 }
        let fits = Int(((rowWidth + gap) / (width + gap)).rounded(.down))
        return max(1, min(fits, cap))
    }

    /// The width one card draws its thumbnails across, given the width the
    /// grid's scroll content is laid out in. The grid spends its own padding
    /// on both sides, the cards split what is left evenly a `cardGap` apart,
    /// and each spends its horizontal padding on both sides. This is the only
    /// arithmetic between what the grid measures and what a row is given, so
    /// a slot too many here overflows a card by real points.
    public static func rowWidth(
        gridWidth: CGFloat, canvasPadding: CGFloat, cardGap: CGFloat, cardPadding: CGFloat
    ) -> CGFloat {
        let content = gridWidth - canvasPadding * 2
        let card = (content - cardGap * CGFloat(columns - 1)) / CGFloat(columns)
        return max(0, card - cardPadding * 2)
    }

    /// A resting card spends its last slot on the +N tile, but never its only
    /// one: a card drawing a tile and no tab at all is the very state
    /// `tabsPerRow`'s own floor exists to prevent.
    public static func restingTabCount(perRow: Int) -> Int { max(1, perRow - 1) }

    /// A workspace whose tabs fit one row shows every tab and has nothing to
    /// expand.
    ///
    /// `newTab` adds the drop placeholder in the FREE SLOT the card's own
    /// cells end on, leaving every drawn tab exactly where it is. A card is a
    /// place the user is aiming at, and a preview that moves or removes one of
    /// its tabs takes away the thing being aimed at: a one-tab card whose only
    /// pane is being dragged would draw the placeholder over that very tab,
    /// leaving nothing to drop back onto.
    ///
    /// It still goes BEFORE a trailing tile, never after it: a tile always ends
    /// the list, so the slot past it is one no tab can reach.
    ///
    /// Only when the card's last row has no free slot does the POST-DROP shape
    /// decide instead, and `closing` (a tab of this card the same drop takes
    /// away) is what that shape is laid out without. A card that can draw
    /// neither is left exactly as it stands, since a hover that reshuffles
    /// cells it cannot explain is worse than one that shows nothing.
    ///
    /// The placeholder is shown at all only while the preview's own rows are
    /// rows the drop leaves behind (`previewKeepsItsRows`). A card that would
    /// gain a row on hover and lose it again on drop shows nothing, and its
    /// accent outline marks it the way it marks every other card-level drop
    /// target.
    public static func cells(tabs: [TabID], expanded: Bool, newTab: Bool = false, closing: TabID? = nil, perRow: Int) -> [GridCell] {
        let drawn = settled(tabs: tabs, expanded: expanded, perRow: perRow)
        guard newTab else { return drawn }
        if let free = inFreeSlot(of: drawn, perRow: perRow) { return free }
        let surviving = surviving(tabs, closing: closing)
        guard previewKeepsItsRows(tabs: surviving.count, expanded: expanded, perRow: perRow) else { return drawn }
        // The shape the card takes once the drop lands, with the tab it
        // creates drawn as the placeholder. Laid out over the post-drop list
        // rather than over the surviving tabs alone, so the trailing tile is
        // the one the drop leaves: five expanded tabs losing one still end
        // the drop with five and the collapse tile they need.
        return settled(tabs: surviving + [createdTab], expanded: expanded, perRow: perRow)
            .map { $0 == .tab(createdTab) ? .newTab : $0 }
    }

    /// `cells` with the placeholder added in the free slot the row they end on
    /// still has, or nil when that row is full. Nothing already drawn moves:
    /// only a trailing tile slides along, since a tile must stay last.
    private static func inFreeSlot(of cells: [GridCell], perRow: Int) -> [GridCell]? {
        guard perRow > 0, !cells.count.isMultiple(of: perRow) else { return nil }
        guard cells.last?.isTile == true else { return cells + [.newTab] }
        return cells.dropLast() + [.newTab] + cells.suffix(1)
    }

    /// Which of the card's own cells the tab this drop creates really lands
    /// in, as an index into the cells the card is drawing now, or nil when the
    /// card will not be drawing that tab at all once the drop lands.
    ///
    /// This is NOT always where the placeholder is drawn. A card with a free
    /// slot keeps its own tabs in place and spends the slot after them, while
    /// herdr appends the created tab once the tab the drop empties is gone, so
    /// the two are one cell apart in the linear order whenever a tab closes,
    /// which is a whole ROW apart on screen whenever that cell ends a row. The
    /// ghost and the landing flash have to use this one, or they settle and
    /// burn where nothing appears.
    ///
    /// Slot `i` is the same place on screen in both shapes: the cells are one
    /// fixed size laid out `perRow` to a row, so a preview that is a row
    /// taller than the card the drop leaves still puts slot `i` where slot `i`
    /// will be.
    public static func landingSlot(tabs: [TabID], expanded: Bool, closing: TabID?, perRow: Int) -> Int? {
        settled(tabs: surviving(tabs, closing: closing) + [createdTab], expanded: expanded, perRow: perRow)
            .firstIndex(of: .tab(createdTab))
    }

    /// Stands in for the tab a previewed drop creates while the post-drop
    /// shape is laid out. Replaced by `.newTab` before the cells leave
    /// `cells`, so it reaches no view and no frame report; the id shape is
    /// one herdr never issues.
    private static let createdTab = TabID(rawValue: "flock.preview.created-tab")

    /// The tabs a card is left holding once the drop lands: a pane leaving
    /// the last pane of its tab takes that tab with it, and herdr appends the
    /// tab it creates, so the created tab takes the slot the closing one
    /// vacates rather than the slot after it.
    public static func surviving(_ tabs: [TabID], closing: TabID?) -> [TabID] {
        guard let closing else { return tabs }
        return tabs.filter { $0 != closing }
    }

    /// Whether the card's trailing tile carries the drop preview in place of
    /// a placeholder: exactly when no placeholder is drawn and there is a tile
    /// to carry it. Its hidden count is the one cell such a drop visibly
    /// changes. A card with no tile has nothing to carry it (the only slot
    /// that changes is a real tab's, whose wash already means that tab takes
    /// the drop), so it previews nothing.
    ///
    /// Read off `cells` rather than restating its rule, so the placeholder and
    /// the tile can never both claim the drop or both refuse it.
    public static func tilePreviewsTheDrop(tabs: [TabID], expanded: Bool, closing: TabID? = nil, perRow: Int) -> Bool {
        let preview = cells(tabs: tabs, expanded: expanded, newTab: true, closing: closing, perRow: perRow)
        return !preview.contains(.newTab) && preview.contains { $0.isTile }
    }

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

    /// `size` is clamped: `rows(_:perRow:)` is public, and a stride of zero
    /// traps rather than returning nothing.
    static func chunked<Item>(_ items: [Item], by size: Int) -> [[Item]] {
        let step = max(1, size)
        return stride(from: 0, to: items.count, by: step).map { Array(items[$0..<min($0 + step, items.count)]) }
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
