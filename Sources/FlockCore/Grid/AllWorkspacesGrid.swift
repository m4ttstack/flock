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

/// What a pointer report over a mini pane asks of the caller's timers.
public enum GridHoverOutcome: Equatable, Sendable {
    /// The pointer is still on the pane the card, or the wait, already
    /// belongs to.
    case unchanged
    /// A wait started, timed out through `hoverIntentElapsed`.
    case waits
    /// A card was already up, so this pane's replaced it with no wait.
    case shows
}

/// The grid's own state: whether it covers the window, and which mini pane
/// the pointer rests on.
public struct AllWorkspacesGridState: Equatable, Sendable {
    /// How long the pointer must rest on one pane before its card shows, so
    /// a sweep across the grid neither flickers cards nor reads every pane
    /// it crosses. In the band desktop tooltips occupy (Windows' hover time
    /// 400ms, GTK 500ms, AppKit's own tooltip 1000ms), at the fast end
    /// because this card is read while scanning a grid rather than to
    /// explain one control.
    public static let hoverIntentDelay: Duration = .milliseconds(500)
    /// How long a card outlives the pointer leaving its pane, or leaving the
    /// card itself. The card is anchored beside its pane with a gap between
    /// them, and that gap is over no pane at all: without this the card would
    /// close as the pointer set out for it, and nothing in it could ever be
    /// clicked. Shorter than the delay, so a card cannot still be up over the
    /// pane the pointer has moved on to.
    public static let hoverCardGrace: Duration = .milliseconds(250)

    public private(set) var isShown = false
    /// The pane whose card is showing.
    public private(set) var hover: PaneID?
    /// The pane waiting out the intent delay.
    public private(set) var pendingHover: PaneID?
    /// The pointer is inside the card itself, which no grace closes.
    public private(set) var isCardHovered = false
    /// A card has been up and the pointer has not been off the panes long
    /// enough to cool: the next pane's card shows at once.
    public private(set) var isWarm = false
    /// A grace is running: the pointer has left the card's pane, or the card,
    /// and has not arrived anywhere that keeps it up.
    private var cardIsLeaving = false

    public init() {}

    public mutating func open() {
        isShown = true
    }

    /// A grid opened again starts at rest.
    public mutating func close() {
        isShown = false
        forgetHover()
    }

    public mutating func toggle() {
        if isShown {
            close()
        } else {
            open()
        }
    }

    /// Every pointer report over a mini pane. The pane the card or the wait
    /// already belongs to asks for nothing: a card names a pane, so moving
    /// within one changes nothing about it. Any other pane shows its card at
    /// once while the grid is warm, and otherwise starts a wait.
    @discardableResult
    public mutating func hoverMoved(pane: PaneID) -> GridHoverOutcome {
        if hover == pane {
            cardIsLeaving = false
            return .unchanged
        }
        if pendingHover == pane { return .unchanged }
        isCardHovered = false
        cardIsLeaving = false
        guard isWarm else {
            hover = nil
            pendingHover = pane
            return .waits
        }
        pendingHover = nil
        hover = pane
        return .shows
    }

    /// A wait that has since moved to another pane, or ended, shows nothing.
    public mutating func hoverIntentElapsed(pane: PaneID) {
        guard pendingHover == pane else { return }
        hover = pane
        pendingHover = nil
        isWarm = true
    }

    /// Only the pane still hovered or waited on answers: moving onto a
    /// neighbor can report the neighbor's entry before this pane's exit. A
    /// showing card is not closed here, only set leaving; true when the caller
    /// must arm the grace that closes it.
    @discardableResult
    public mutating func hoverEnded(pane: PaneID) -> Bool {
        if pendingHover == pane {
            pendingHover = nil
        }
        guard hover == pane, !isCardHovered else { return false }
        cardIsLeaving = true
        return true
    }

    /// The pointer has reached the card itself, which outranks every grace:
    /// the card stays up for as long as the pointer is inside it.
    public mutating func cardEntered() {
        guard hover != nil else { return }
        isCardHovered = true
        cardIsLeaving = false
    }

    /// True when the caller must arm the grace: the pointer may be on its way
    /// back to the pane, which keeps the card.
    @discardableResult
    public mutating func cardExited() -> Bool {
        guard isCardHovered else { return false }
        isCardHovered = false
        guard hover != nil else { return false }
        cardIsLeaving = true
        return true
    }

    /// The grace ran out with the pointer on neither the pane nor the card,
    /// so the card closes and the grid cools: the next one waits again.
    public mutating func hoverGraceElapsed() {
        guard cardIsLeaving else { return }
        cardIsLeaving = false
        hover = nil
        isWarm = false
    }

    /// Hover reports stop while the button is held, so whatever was hovered
    /// when a drag began is stale by the time it ends.
    public mutating func dragBegan() {
        forgetHover()
    }

    /// Never while a drag is in flight, when the card would cover the
    /// thumbnails the drop is aimed at.
    public func hoverCard(dragInFlight: Bool) -> PaneID? {
        dragInFlight ? nil : hover
    }

    private mutating func forgetHover() {
        hover = nil
        pendingHover = nil
        isCardHovered = false
        cardIsLeaving = false
        isWarm = false
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
