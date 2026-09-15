import CoreGraphics

/// One slot in a workspace card of the All Workspaces grid.
public enum GridCell: Hashable, Sendable {
    case tab(TabID)
    /// Stands in for the tabs a resting card does not show.
    case moreTabs(hidden: Int)
    /// Ends an expanded card and folds it back to rest.
    case collapse
}

/// Which tabs a workspace card shows and how they wrap.
public enum GridCardLayout {
    public static let tabsPerRow = 4
    /// A resting card spends its last slot on the +N tile.
    public static let restingTabCount = tabsPerRow - 1
    public static let columns = 2

    /// A workspace whose tabs fit one row shows every tab and has nothing to
    /// expand.
    public static func cells(tabs: [TabID], expanded: Bool) -> [GridCell] {
        guard tabs.count > tabsPerRow else { return tabs.map(GridCell.tab) }
        guard expanded else {
            return tabs.prefix(restingTabCount).map(GridCell.tab) + [.moreTabs(hidden: tabs.count - restingTabCount)]
        }
        return tabs.map(GridCell.tab) + [.collapse]
    }

    public static func rows(tabs: [TabID], expanded: Bool) -> [[GridCell]] {
        chunked(cells(tabs: tabs, expanded: expanded), by: tabsPerRow)
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

    /// What a fired dwell does to the grid. A thumbnail reveals its tab in
    /// the window, so the grid gives way to it; the tab selection itself is
    /// the view model's. True when the grid opened or closed, which replaces
    /// every surface under the pointer.
    @discardableResult
    public mutating func springLoaded(_ target: DropTarget) -> Bool {
        let wasShown = isShown
        switch target {
        case .allWorkspaces:
            open()
        case .moreTabs(let workspace):
            if isShown {
                expanded.insert(workspace)
            }
        case .tabThumbnail:
            close()
        case .paneEdge, .paneInterior, .tabStrip, .workspaceThumbnail, .newTab, .newWorkspace, .workspaceRail:
            break
        }
        return isShown != wasShown
    }
}

/// The rail's pinned "All workspaces" row and the room the rail makes for it
/// while a pane drag shows it.
public enum AllWorkspacesEntry {
    /// How far the rows' scroll content ends above the rail's bottom, so a
    /// fully scrolled rail stops its last row `gap` above the entry row
    /// rather than under it.
    public static func railBottomMargin(restingMargin: CGFloat, entryHeight: CGFloat, entryBottomInset: CGFloat, gap: CGFloat) -> CGFloat {
        max(restingMargin, entryBottomInset + entryHeight + gap)
    }

    /// The part of the rail's viewport above the entry row: where its rows
    /// can be hit and where its bottom scroll band sits.
    public static func railViewport(_ viewport: CGRect?, above entry: CGRect?) -> CGRect? {
        guard let viewport, let entry else { return viewport }
        var clipped = viewport
        clipped.size.height = max(0, min(viewport.maxY, entry.minY) - viewport.minY)
        return clipped
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
