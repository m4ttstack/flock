import CoreGraphics
import XCTest
@testable import FlockCore

final class AllWorkspacesGridTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let p1 = PaneID(rawValue: "w1:p1")
    private let p2 = PaneID(rawValue: "w1:p2")

    /// One row width to lay the card shapes out against. Not the window's
    /// own answer, which `slots(gridWidth:)` derives; the shapes here are
    /// about how a card fills whatever count it is given.
    private let perRow = 4

    private func tabs(_ count: Int) -> [TabID] {
        (1...max(count, 1)).prefix(count).map { TabID(rawValue: "w1:t\($0)") }
    }

    // MARK: - card layout

    func testACardShowsEveryTabItHas() {
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(1), perRow: perRow), tabs(1).map(GridCell.tab))
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(9), perRow: perRow), tabs(9).map(GridCell.tab))
    }

    func testACardWrapsItsTabsAtTheSlotCount() {
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(9), perRow: perRow).map(\.count), [4, 4, 1])
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(8), perRow: perRow).map(\.count), [4, 4], "no empty row")
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(9), perRow: 7).map(\.count), [7, 2])
    }

    // MARK: - how many slots a row is divided into

    /// The design's own window, spelled from `ChromeMetrics.Grid`: 900pt
    /// across, 13pt of grid padding either side, two cards 13pt apart, each
    /// spending 13pt of padding per side, thumbnails 120pt wide and 10pt
    /// apart.
    private func rowWidth(gridWidth: CGFloat) -> CGFloat {
        GridCardLayout.rowWidth(gridWidth: gridWidth, canvasPadding: 13, cardGap: 13, cardPadding: 13)
    }

    private func slots(gridWidth: CGFloat) -> Int {
        GridCardLayout.tabsPerRow(rowWidth: rowWidth(gridWidth: gridWidth), width: 120, gap: 10)
    }

    /// The narrowest window the app allows (`MainWindow` sets a 900pt
    /// minimum) holds three thumbnails at their own width, with room to spare
    /// rather than stretching them to fill the row.
    func testTheNarrowestWindowHoldsThreeThumbnailsAtTheirOwnWidth() {
        XCTAssertEqual(slots(gridWidth: 900), 3)
        let filled = 120 * 3 + 10 * 2
        XCTAssertLessThanOrEqual(CGFloat(filled), rowWidth(gridWidth: 900))
        XCTAssertGreaterThan(CGFloat(filled + 10 + 120), rowWidth(gridWidth: 900), "a fourth slot would have fit")
        XCTAssertEqual(slots(gridWidth: 1200), 4)
        XCTAssertEqual(slots(gridWidth: 1600), 5)
        XCTAssertEqual(slots(gridWidth: 2000), 7, "a wide window spends its width on more slots")
    }

    /// A thumbnail is the same size at every window, so the row gains slots
    /// as the window widens and gives them up as it narrows, monotonically,
    /// never below one, and never leaving room for another.
    func testTheSlotCountFollowsTheWindowAndNeverReachesZero() {
        var previous = 0
        for width in stride(from: CGFloat(200), through: 3000, by: 25) {
            let count = slots(gridWidth: width)
            XCTAssertGreaterThanOrEqual(count, 1, "\(width): a card with no slot at all")
            XCTAssertGreaterThanOrEqual(count, previous, "\(width): slots dropped as the window widened")
            let filled = CGFloat(count) * 120 + CGFloat(count - 1) * 10
            if count > 1 {
                XCTAssertLessThanOrEqual(filled, rowWidth(gridWidth: width), "\(width): the row cannot hold that many")
            }
            XCTAssertGreaterThan(filled + 10 + 120, rowWidth(gridWidth: width), "\(width): another slot would have fit")
            previous = count
        }
        XCTAssertEqual(GridCardLayout.tabsPerRow(rowWidth: 0, width: 120, gap: 10), 1, "the floor")
    }

    func testARowOfZeroSlotsNeverStrides() {
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(2), perRow: 0).map(\.count), [1, 1])
    }

    // MARK: - the new-tab placeholder's slot

    /// Where the placeholder actually lands, read off the card's own rows --
    /// the same rows the card draws, so nothing here is a parallel model of
    /// the geometry.
    private func placeholderSlot(tabs list: [TabID], closing: TabID? = nil, perRow: Int? = nil) -> (row: Int, column: Int)? {
        let slots = perRow ?? self.perRow
        let rows = GridCardLayout.rows(GridCardLayout.cells(tabs: list, newTab: true, closing: closing, perRow: slots), perRow: slots)
        for (row, cells) in rows.enumerated() {
            if let column = cells.firstIndex(of: .newTab) { return (row, column) }
        }
        return nil
    }

    /// Where the real tab lands, from the same function over the tabs the
    /// card is left holding: the one the drop empties gone, the created one
    /// appended.
    private func landingSlot(tabs list: [TabID], closing: TabID? = nil) -> (row: Int, column: Int)? {
        let added = GridCardLayout.surviving(list, closing: closing) + [TabID(rawValue: "w1:tNEW")]
        let rows = GridCardLayout.rows(tabs: added, perRow: perRow)
        for (row, cells) in rows.enumerated() {
            if let column = cells.firstIndex(of: .tab(TabID(rawValue: "w1:tNEW"))) { return (row, column) }
        }
        return nil
    }

    /// With no tab closing, the placeholder stands in exactly the slot the
    /// created tab takes, at every count, and opens a row only when the drop
    /// really does.
    func testThePlaceholderTakesTheSlotTheTabWillTake() {
        for count in 0...12 {
            let placeholder = placeholderSlot(tabs: tabs(count))
            let landing = landingSlot(tabs: tabs(count))
            XCTAssertEqual(placeholder?.row, landing?.row, "\(count) tabs")
            XCTAssertEqual(placeholder?.column, landing?.column, "\(count) tabs")
            XCTAssertEqual(
                GridCardLayout.rows(tabs: tabs(count), newTab: true, perRow: perRow).count,
                GridCardLayout.rows(tabs: tabs(count + 1), perRow: perRow).count,
                "\(count) tabs: the preview's rows are the rows the drop leaves"
            )
        }
    }

    // MARK: - a drop that empties one of the card's own tabs

    /// Every tab the card is drawing stays exactly where it is while its last
    /// row has a free slot, the tab the drop empties included: a card is what
    /// the user is aiming at, and a preview that takes one of its tabs away
    /// takes away the thing being aimed at.
    func testEveryDrawnTabKeepsItsSlotWhateverTheDropEmpties() {
        let all = tabs(3)
        let standing: [GridCell] = [.tab(all[0]), .tab(all[1]), .tab(all[2]), .newTab]
        for closing in [nil, all[0], all[2]] as [TabID?] {
            XCTAssertEqual(
                GridCardLayout.cells(tabs: all, newTab: true, closing: closing, perRow: perRow),
                standing, "closing: \(String(describing: closing))"
            )
        }
    }

    /// A card of one tab, whose only pane is the one being dragged. The tab
    /// it came from stays drawn in its own slot, so there is still something
    /// to drop back onto, and the placeholder takes the free slot beside it.
    func testACardOfOneTabKeepsThatTabAndPutsThePlaceholderBesideIt() {
        let only = tabs(1)
        XCTAssertEqual(
            GridCardLayout.cells(tabs: only, newTab: true, closing: only[0], perRow: perRow),
            [.tab(only[0]), .newTab]
        )
    }

    /// A card whose last row is full, losing a tab to the same drop: an
    /// appended placeholder would open a row the drop closes again, so the
    /// preview is the card the drop leaves behind.
    func testAFullRowLosingATabPreviewsThePostDropShape() {
        let all = tabs(8)
        let created = TabID(rawValue: "w1:tNEW")
        let preview = GridCardLayout.cells(tabs: all, newTab: true, closing: all[0], perRow: perRow)
        XCTAssertEqual(
            preview.map { $0 == .newTab ? GridCell.tab(created) : $0 },
            GridCardLayout.cells(tabs: GridCardLayout.surviving(all, closing: all[0]) + [created], perRow: perRow)
        )
        XCTAssertEqual(GridCardLayout.rows(preview, perRow: perRow).count, 2)
        XCTAssertEqual(
            GridCardLayout.rows(tabs: all, newTab: true, perRow: perRow).count, 3,
            "with no tab closing, the full card really does gain a row"
        )
    }

    /// The whole rule, over every card shape. A card whose last row still has
    /// a free slot keeps every drawn cell exactly where it is and spends that
    /// slot on the placeholder; only a full row falls back to the post-drop
    /// shape, which is the one path that may take the emptied tab away.
    func testAFreeSlotKeepsEveryDrawnCellAndOnlyAFullRowFallsBack() {
        let created = TabID(rawValue: "w1:tNEW")
        for count in 1...12 {
            let list = tabs(count)
            for closing in [nil, list[0], list[count - 1]] as [TabID?] {
                let drawn = GridCardLayout.cells(tabs: list, perRow: perRow)
                let preview = GridCardLayout.cells(tabs: list, newTab: true, closing: closing, perRow: perRow)
                let shape = "\(count) tabs, closing: \(String(describing: closing))"
                XCTAssertEqual(preview.last, .newTab, shape)
                if drawn.count.isMultiple(of: perRow) {
                    XCTAssertEqual(
                        preview.map { $0 == .newTab ? GridCell.tab(created) : $0 },
                        GridCardLayout.cells(tabs: GridCardLayout.surviving(list, closing: closing) + [created], perRow: perRow),
                        "a full row must fall back to the card the drop leaves behind: \(shape)"
                    )
                } else {
                    XCTAssertEqual(Array(preview.dropLast()), drawn, "a drawn cell moved for a card with a free slot: \(shape)")
                }
            }
        }
    }

    /// `landingSlot` is where the created tab really ends up: the index it
    /// names in the card's own cells is the index that tab takes once the
    /// drop lands.
    func testTheLandingSlotIsWhereTheCreatedTabReallyEndsUp() {
        let created = TabID(rawValue: "w1:tNEW")
        for count in 1...16 {
            let list = tabs(count)
            for closing in [nil, list[0], list[count - 1]] as [TabID?] {
                let after = GridCardLayout.surviving(list, closing: closing) + [created]
                XCTAssertEqual(
                    GridCardLayout.landingSlot(tabs: list, closing: closing), after.firstIndex(of: created),
                    "\(count) tabs, closing: \(String(describing: closing))"
                )
            }
        }
    }

    /// Where the placeholder and the landing slot disagree: a drop that
    /// empties one of the card's own tabs keeps that tab drawn, so the
    /// placeholder sits one cell past where the created tab really lands. The
    /// full-row fallback is what keeps the two in the same row.
    func testADropThatEmptiesATabLandsOneCellBeforeThePlaceholderInTheSameRow() {
        for count in 1...12 where !count.isMultiple(of: perRow) {
            let list = tabs(count)
            let placeholder = placeholderSlot(tabs: list, closing: list[0])
            let landing = landingSlot(tabs: list, closing: list[0])
            XCTAssertEqual(placeholder?.row, landing?.row, "\(count) tabs")
            XCTAssertEqual(placeholder.map { $0.column - 1 }, landing?.column, "\(count) tabs")
        }
    }

    func testCardsPairUpTwoToARowInRailOrder() {
        XCTAssertEqual(GridCardLayout.cardRows([1, 2, 3, 4, 5]), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(GridCardLayout.cardRows([Int]()), [])
    }

    // MARK: - grid state

    func testClosingForgetsTheSelection() {
        var state = AllWorkspacesGridState()
        state.open()
        state.select(pane: p1)
        state.close()
        XCTAssertFalse(state.isShown)
        XCTAssertNil(state.selected)
        state.open()
        XCTAssertNil(state.selected, "a grid opened again starts with nothing selected")
    }

    // MARK: - selection

    func testAClickSelectsAPaneAndAnotherMovesTheSelection() {
        var state = AllWorkspacesGridState()
        state.open()
        state.select(pane: p1)
        XCTAssertEqual(state.selected, p1)
        state.select(pane: p2)
        XCTAssertEqual(state.selected, p2)
        state.deselect()
        XCTAssertNil(state.selected)
        XCTAssertTrue(state.isShown)
    }

    func testNothingIsSelectedWhileTheGridIsClosed() {
        var state = AllWorkspacesGridState()
        state.select(pane: p1)
        XCTAssertNil(state.selected)
    }

    func testEscPutsTheSelectionDownBeforeTheGrid() {
        var state = AllWorkspacesGridState()
        state.open()
        state.select(pane: p1)
        state.escape()
        XCTAssertNil(state.selected)
        XCTAssertTrue(state.isShown, "the first Esc belongs to the selection")
        state.escape()
        XCTAssertFalse(state.isShown)
    }

    func testADragBeginningPutsTheSelectionDown() {
        var state = AllWorkspacesGridState()
        state.open()
        state.select(pane: p1)
        state.dragBegan()
        XCTAssertNil(state.selected)
        XCTAssertTrue(state.isShown)
    }

    func testASelectedPaneThatClosesIsForgotten() {
        var state = AllWorkspacesGridState()
        state.open()
        state.select(pane: p1)
        state.reconcile(livePanes: [p2])
        XCTAssertNil(state.selected)
    }

    func testADragKeepsOverviewsFocusedPane() {
        var grid = AllWorkspacesGridState()
        grid.open()
        grid.focus(pane: p1)
        grid.dragBegan()
        XCTAssertEqual(grid.focused, p1, "Arrange's drag leaves Overview's place alone")
        XCTAssertTrue(grid.isShown)
    }

    func testAPaneIsFocusedOnlyWhileTheGridIsShown() {
        var grid = AllWorkspacesGridState()
        grid.focus(pane: PaneID(rawValue: "p1"))
        XCTAssertNil(grid.focused, "nothing to focus inside a closed view")
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        XCTAssertEqual(grid.focused, PaneID(rawValue: "p1"))
        grid.unfocus()
        XCTAssertNil(grid.focused)
    }

    func testLeavingTheViewPutsTheFocusedPaneDownByDefault() {
        var grid = AllWorkspacesGridState()
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        grid.close()
        grid.open()
        XCTAssertNil(grid.focused, "Overview opens on its lanes again")
    }

    func testKeepingTheFocusedPaneReturnsToItAfterLeaving() {
        var grid = AllWorkspacesGridState()
        grid.keepsFocusedPane = true
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        grid.toggle()
        grid.toggle()
        XCTAssertEqual(grid.focused, PaneID(rawValue: "p1"), "Overview remembers its place")
        grid.unfocus()
        XCTAssertNil(grid.focused, "only going back leaves it")
    }

    func testAFocusedPaneThatClosesReturnsToOverview() {
        var grid = AllWorkspacesGridState()
        grid.open()
        grid.focus(pane: PaneID(rawValue: "p1"))
        grid.reconcile(livePanes: [PaneID(rawValue: "p1"), PaneID(rawValue: "p2")])
        XCTAssertEqual(grid.focused, PaneID(rawValue: "p1"))
        grid.reconcile(livePanes: [PaneID(rawValue: "p2")])
        XCTAssertNil(grid.focused)
        XCTAssertTrue(grid.isShown, "the view stays open on Overview")
    }

    func testEscBelongsToTheTerminalWhileAPaneIsFocused() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridYieldsEscape: true, railTakesEscape: false), .focusedView)
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridYieldsEscape: false, railTakesEscape: false), .grid)
        XCTAssertEqual(EscapeRoute.route(dragIdle: false, gridShown: true, gridYieldsEscape: true, railTakesEscape: false), .drag)
    }

    // MARK: - Esc

    func testALiveDragAlwaysOwnsEsc() {
        for grid in [false, true] {
            for rail in [false, true] {
                XCTAssertEqual(EscapeRoute.route(dragIdle: false, gridShown: grid, gridYieldsEscape: false, railTakesEscape: rail), .drag)
            }
        }
    }

    func testAnIdleEscClosesAShownGridBeforeTheRailSelectionSeesIt() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridYieldsEscape: false, railTakesEscape: true), .grid)
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridYieldsEscape: false, railTakesEscape: false), .grid)
    }

    func testWithNoGridEscIsTheRailsOrTheTerminals() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: false, gridYieldsEscape: false, railTakesEscape: true), .railSelection)
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: false, gridYieldsEscape: false, railTakesEscape: false), .focusedView)
    }

    // MARK: - last line requests

    func testALastLineIsFetchedOncePerRevision() {
        var requests = LastLineRequests()
        XCTAssertTrue(requests.begin(pane: p1, revision: 3))
        XCTAssertFalse(requests.begin(pane: p1, revision: 3))
        XCTAssertTrue(requests.begin(pane: p1, revision: 4))
        XCTAssertTrue(requests.begin(pane: p2, revision: 3), "revisions are per pane")
    }

    func testAReplyForARevisionThePaneHasMovedPastIsStale() {
        var requests = LastLineRequests()
        _ = requests.begin(pane: p1, revision: 3)
        XCTAssertTrue(requests.accepts(pane: p1, revision: 3))
        _ = requests.begin(pane: p1, revision: 4)
        XCTAssertFalse(requests.accepts(pane: p1, revision: 3))
        XCTAssertTrue(requests.accepts(pane: p1, revision: 4))
        XCTAssertFalse(requests.accepts(pane: PaneID(rawValue: "w1:p9"), revision: 4), "a pane never asked for has nothing to accept")
    }
}
