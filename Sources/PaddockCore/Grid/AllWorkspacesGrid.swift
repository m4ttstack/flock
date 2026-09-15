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

/// A slot's place in a card: which row it falls in and which of that row's
/// `tabsPerRow` columns. Every row keeps all its slots, so two cells with the
/// same place occupy the same rect.
public struct GridSlot: Equatable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Which tabs a workspace card shows and how they wrap.
public enum GridCardLayout {
    public static let tabsPerRow = 4
    /// A resting card spends its last slot on the +N tile.
    public static let restingTabCount = tabsPerRow - 1
    public static let columns = 2

    /// A workspace whose tabs fit one row shows every tab and has nothing to
    /// expand. `newTab` appends the drop placeholder, which is why it lands
    /// in the first free slot after everything the card already draws.
    public static func cells(tabs: [TabID], expanded: Bool, newTab: Bool = false) -> [GridCell] {
        settled(tabs: tabs, expanded: expanded) + (newTab ? [.newTab] : [])
    }

    private static func settled(tabs: [TabID], expanded: Bool) -> [GridCell] {
        guard tabs.count > tabsPerRow else { return tabs.map(GridCell.tab) }
        guard expanded else {
            return tabs.prefix(restingTabCount).map(GridCell.tab) + [.moreTabs(hidden: tabs.count - restingTabCount)]
        }
        return tabs.map(GridCell.tab) + [.collapse]
    }

    public static func rows(tabs: [TabID], expanded: Bool, newTab: Bool = false) -> [[GridCell]] {
        chunked(cells(tabs: tabs, expanded: expanded, newTab: newTab), by: tabsPerRow)
    }

    /// Where the `newTab` placeholder sits, which is the first slot no
    /// settled cell holds. The card's own rows are chunked from the same
    /// list, so this is the placeholder's real place, not a parallel guess
    /// at it.
    public static func newTabSlot(tabs: [TabID], expanded: Bool) -> GridSlot {
        slot(atIndex: settled(tabs: tabs, expanded: expanded).count)
    }

    public static func slot(atIndex index: Int) -> GridSlot {
        GridSlot(row: index / tabsPerRow, column: index % tabsPerRow)
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
