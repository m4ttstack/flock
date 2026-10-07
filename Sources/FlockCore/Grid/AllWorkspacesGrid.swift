import CoreGraphics

/// One slot in a workspace card of the All Workspaces grid.
public enum GridCell: Hashable, Sendable {
    case tab(TabID)
    /// The tab a drop on this card's empty space is about to create, drawn
    /// in the slot that tab will take.
    case newTab
}

/// Which tabs a workspace card shows and how they wrap. A card shows every
/// tab it has.
///
/// How many thumbnails a row holds is the window's answer, not a constant:
/// every function that shapes a card takes `perRow` so the cells, the rows
/// and the placeholder are all laid out against the same count.
public enum GridCardLayout {
    public static let columns = 2

    /// How many thumbnails of `width` one row of `rowWidth` holds. A
    /// thumbnail is the same size at every window, so a wider window buys
    /// slots and a narrower one gives them up, and whatever is left over sits
    /// at the end of the row.
    ///
    /// Never zero: a row too narrow for even one thumbnail still draws one,
    /// overflowing its card rather than drawing a card whose tabs cannot be
    /// seen, reached or dropped on at all.
    public static func tabsPerRow(rowWidth: CGFloat, width: CGFloat, gap: CGFloat) -> Int {
        guard rowWidth > 0, width > 0 else { return 1 }
        let fits = Int(((rowWidth + gap) / (width + gap)).rounded(.down))
        return max(1, fits)
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

    /// `newTab` adds the drop placeholder after the card's tabs, leaving
    /// every drawn tab exactly where it is. A card is a place the user is
    /// aiming at, and a preview that moves or removes one of its tabs takes
    /// away the thing being aimed at: a one-tab card whose only pane is being
    /// dragged would draw the placeholder over that very tab, leaving nothing
    /// to drop back onto.
    ///
    /// The exception is a card whose last row is full while the same drop
    /// takes one of its tabs away (`closing`): a placeholder appended there
    /// opens a row the drop closes again, so the preview is the shape the
    /// drop leaves instead, without the closing tab.
    public static func cells(tabs: [TabID], newTab: Bool = false, closing: TabID? = nil, perRow: Int) -> [GridCell] {
        let drawn = tabs.map(GridCell.tab)
        guard newTab else { return drawn }
        guard perRow > 0, tabs.count.isMultiple(of: perRow) else { return drawn + [.newTab] }
        return surviving(tabs, closing: closing).map(GridCell.tab) + [.newTab]
    }

    /// Which of the card's own cells the tab this drop creates really lands
    /// in, as an index into the cells the card is drawing now.
    ///
    /// This is NOT always where the placeholder is drawn. A card with a free
    /// slot keeps its own tabs in place and spends the slot after them, while
    /// herdr appends the created tab once the tab the drop empties is gone, so
    /// the two are one cell apart whenever a tab closes. The ghost and the
    /// landing flash have to use this one, or they settle and burn where
    /// nothing appears.
    public static func landingSlot(tabs: [TabID], closing: TabID?) -> Int {
        surviving(tabs, closing: closing).count
    }

    /// The tabs a card is left holding once the drop lands: a pane leaving
    /// the last pane of its tab takes that tab with it, and herdr appends the
    /// tab it creates, so the created tab takes the slot the closing one
    /// vacates rather than the slot after it.
    public static func surviving(_ tabs: [TabID], closing: TabID?) -> [TabID] {
        guard let closing else { return tabs }
        return tabs.filter { $0 != closing }
    }

    /// The gap a point names among cells that wrap: rows top to bottom, cells
    /// left to right inside a row. A cell comes before the point when the
    /// point is past that cell's row entirely, or in its row and past its
    /// centre, which is the strip's own centre-crossing rule applied one row
    /// at a time. The count of such cells is the insert index, so a point
    /// over a cell's own body still names the gap on one side of it.
    ///
    /// `cells` are the card's TAB cells in the order it draws them, which is
    /// its workspace's tab order, so the answer is an index into that list
    /// too.
    public static func insertIndex(at point: CGPoint, cells: [CGRect]) -> Int {
        cells.filter { cell in
            if point.y > cell.maxY { return true }
            if point.y < cell.minY { return false }
            return point.x > cell.midX
        }.count
    }

    public static func rows(tabs: [TabID], newTab: Bool = false, perRow: Int) -> [[GridCell]] {
        rows(cells(tabs: tabs, newTab: newTab, perRow: perRow), perRow: perRow)
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

/// The grid's own state: whether it covers the window, and which mini pane
/// Arrange has selected.
public struct AllWorkspacesGridState: Equatable, Sendable {
    public private(set) var isShown = false
    /// The mini pane a click selected: outlined, and what Return opens. It
    /// stays until something else is selected or it is put down.
    public private(set) var selected: PaneID?
    /// The pane Overview has opened in its focused view. Overview's own
    /// place: it survives the grid closing, Arrange being shown and a drag,
    /// so returning to Overview returns to it. Only going back, or the pane
    /// closing, ends it.
    public private(set) var focused: PaneID?
    /// The workspace Arrange has zoomed into, its island alone filling the
    /// canvas. Never kept past the grid closing: Arrange always opens on
    /// every workspace.
    public private(set) var zoomed: WorkspaceID?

    public init() {}

    public mutating func zoom(into workspace: WorkspaceID) {
        guard isShown else { return }
        zoomed = workspace
    }

    public mutating func unzoom() {
        zoomed = nil
    }

    public mutating func focus(pane: PaneID) {
        guard isShown else { return }
        focused = pane
    }

    public mutating func unfocus() {
        focused = nil
    }

    /// A focused pane that herdr no longer reports leaves the view on
    /// Overview rather than on an empty canvas, and a selected one leaves
    /// nothing for Return to open.
    public mutating func reconcile(livePanes: Set<PaneID>) {
        if let focused, !livePanes.contains(focused) { self.focused = nil }
        if let selected, !livePanes.contains(selected) { self.selected = nil }
    }

    public mutating func open() {
        isShown = true
    }

    /// A grid opened again starts with nothing selected.
    public mutating func close() {
        isShown = false
        selected = nil
        zoomed = nil
    }

    public mutating func toggle() {
        if isShown {
            close()
        } else {
            open()
        }
    }

    public mutating func select(pane: PaneID) {
        guard isShown else { return }
        selected = pane
    }

    public mutating func deselect() {
        selected = nil
    }

    /// A zoom is left in one Esc, selection kept. Outside a zoom Esc puts a
    /// selection down first and the grid only once none is up, so each Esc
    /// undoes one step and never throws away the grid behind it.
    public mutating func escape() {
        if zoomed != nil {
            zoomed = nil
        } else if selected != nil {
            selected = nil
        } else {
            close()
        }
    }

    /// A drag carries the pointer away from whatever was selected.
    public mutating func dragBegan() {
        selected = nil
    }
}

/// Who an Esc belongs to.
public enum EscapeRoute: Equatable, Sendable {
    case drag
    case grid
    case railSelection
    case focusedView

    /// A live drag owns Esc as its cancel. The grid yields Esc to what is
    /// inside it when that is a live terminal (a focused pane) or a text
    /// field (a rename), whose key it is. Otherwise the grid covers the
    /// rail, so it outranks the rail's selection, and what is left reaches
    /// the focused terminal.
    public static func route(dragIdle: Bool, gridShown: Bool, gridYieldsEscape: Bool, railTakesEscape: Bool) -> EscapeRoute {
        guard dragIdle else { return .drag }
        if gridShown { return gridYieldsEscape ? .focusedView : .grid }
        return railTakesEscape ? .railSelection : .focusedView
    }
}
