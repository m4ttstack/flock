import CoreGraphics
import XCTest
@testable import PaddockCore

final class AllWorkspacesGridTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")
    private let p1 = PaneID(rawValue: "w1:p1")
    private let p2 = PaneID(rawValue: "w1:p2")
    private let p3 = PaneID(rawValue: "w1:p3")

    /// The slot count a card row holds at the window paddock's chrome is
    /// designed on.
    private let perRow = 4

    private func tabs(_ count: Int) -> [TabID] {
        (1...max(count, 1)).prefix(count).map { TabID(rawValue: "w1:t\($0)") }
    }

    // MARK: - card layout

    func testACardOfFourOrFewerTabsShowsThemAllWithNoTile() {
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(1), expanded: false, perRow: perRow), tabs(1).map(GridCell.tab))
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(4), expanded: false, perRow: perRow), tabs(4).map(GridCell.tab))
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(4), expanded: true, perRow: perRow), tabs(4).map(GridCell.tab), "nothing is hidden, so there is nothing to expand or collapse")
    }

    func testARestingCardOfFiveTabsShowsThreeAndATileForTheOtherTwo() {
        let all = tabs(5)
        XCTAssertEqual(GridCardLayout.cells(tabs: all, expanded: false, perRow: perRow), [.tab(all[0]), .tab(all[1]), .tab(all[2]), .moreTabs(hidden: 2)])
    }

    func testARestingCardOfNineTabsIsOneRowEndingInPlusSix() {
        let rows = GridCardLayout.rows(tabs: tabs(9), expanded: false, perRow: perRow)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].last, .moreTabs(hidden: 6))
    }

    func testAnExpandedCardShowsEveryTabFourPerRowThenTheCollapseTile() {
        let all = tabs(9)
        let rows = GridCardLayout.rows(tabs: all, expanded: true, perRow: perRow)
        XCTAssertEqual(rows.map(\.count), [4, 4, 2])
        XCTAssertEqual(rows.flatMap { $0 }, all.map(GridCell.tab) + [.collapse])
    }

    func testAnExpandedCardWhoseTabsAndTileFillRowsExactlyAddsNoEmptyRow() {
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(7), expanded: true, perRow: perRow).map(\.count), [4, 4])
    }

    // MARK: - how many slots a row is divided into

    /// The design's own window, spelled from `ChromeMetrics.Grid`: 900pt
    /// across, 13pt of grid padding either side, two cards 13pt apart, each
    /// spending 13pt of padding per side, thumbnails 93pt wide and 10pt apart.
    private func rowWidth(gridWidth: CGFloat) -> CGFloat {
        GridCardLayout.rowWidth(gridWidth: gridWidth, canvasPadding: 13, cardGap: 13, cardPadding: 13)
    }

    private func slots(gridWidth: CGFloat) -> Int {
        GridCardLayout.tabsPerRow(rowWidth: rowWidth(gridWidth: gridWidth), width: 93, gap: 10)
    }

    /// The window the chrome is designed on is also the narrowest one it
    /// allows (`MainWindow` sets a 900pt minimum), and it draws the four slots
    /// it always did at the width it always drew them, with room to spare
    /// rather than stretching them to fill the row.
    func testTheDesignWindowStillHoldsFourThumbnailsAtTheirOwnWidth() {
        XCTAssertEqual(slots(gridWidth: 900), 4)
        let filled = 93 * 4 + 10 * 3
        XCTAssertLessThanOrEqual(CGFloat(filled), rowWidth(gridWidth: 900))
        XCTAssertGreaterThan(CGFloat(filled + 10 + 93), rowWidth(gridWidth: 900), "a fifth slot would have fit")
    }

    /// A thumbnail is the same size at every window, so the row gains slots
    /// as the window widens and gives them up as it narrows, monotonically
    /// and never below one.
    func testTheSlotCountFollowsTheWindowAndNeverReachesZero() {
        var previous = 0
        for width in stride(from: CGFloat(200), through: 2400, by: 25) {
            let count = slots(gridWidth: width)
            XCTAssertGreaterThanOrEqual(count, 1, "\(width): a card with no slot at all")
            XCTAssertGreaterThanOrEqual(count, previous, "\(width): slots dropped as the window widened")
            let filled = CGFloat(count) * 93 + CGFloat(count - 1) * 10
            if count > 1 {
                XCTAssertLessThanOrEqual(filled, rowWidth(gridWidth: width), "\(width): the row cannot hold that many")
            }
            XCTAssertGreaterThan(filled + 10 + 93, rowWidth(gridWidth: width), "\(width): another slot would have fit")
            previous = count
        }
        XCTAssertLessThan(slots(gridWidth: 700), 4, "a row too narrow for four gave up nothing")
        XCTAssertGreaterThan(slots(gridWidth: 1600), 4, "a wide window gained nothing")
    }

    /// The slot count is what the tile, the placeholder and the wrapping all
    /// read, so a row at a wider window really does hold more tabs before it
    /// wraps and spends its last slot on the tile at the same place.
    func testEveryPartOfACardFollowsTheSlotCount() {
        let wide = 6
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(6), expanded: false, perRow: wide).map(\.count), [6])
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(6), expanded: false, perRow: perRow).map(\.count), [4])
        XCTAssertEqual(
            GridCardLayout.cells(tabs: tabs(7), expanded: false, perRow: wide).last, .moreTabs(hidden: 2),
            "a resting card over its cap still spends its last slot on the tile"
        )
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(6), expanded: false, perRow: wide), tabs(6).map(GridCell.tab))
        XCTAssertEqual(
            GridCardLayout.rows(tabs: tabs(9), expanded: true, perRow: wide).map(\.count), [6, 4],
            "ten cells over six slots"
        )
        XCTAssertEqual(
            GridCardLayout.cells(tabs: tabs(3), expanded: false, perRow: 2), [.tab(tabs(3)[0]), .moreTabs(hidden: 2)],
            "a narrow card still spends its last slot on the tile"
        )
    }

    // MARK: - the new-tab placeholder's slot

    /// Where the placeholder actually lands, read off the card's own rows --
    /// the same rows the card draws, so nothing here is a parallel model of
    /// the geometry.
    private func placeholderSlot(tabs list: [TabID], expanded: Bool, closing: TabID? = nil) -> (row: Int, column: Int)? {
        let rows = GridCardLayout.rows(GridCardLayout.cells(tabs: list, expanded: expanded, newTab: true, closing: closing, perRow: perRow), perRow: perRow)
        for (row, cells) in rows.enumerated() {
            if let column = cells.firstIndex(of: .newTab) { return (row, column) }
        }
        return nil
    }

    /// Where the real tab lands, from the same function over the tabs the
    /// card is left holding: the one the drop empties gone, the created one
    /// appended.
    private func landingSlot(tabs list: [TabID], expanded: Bool, closing: TabID? = nil) -> (row: Int, column: Int)? {
        let added = GridCardLayout.surviving(list, closing: closing) + [TabID(rawValue: "w1:tNEW")]
        let rows = GridCardLayout.rows(tabs: added, expanded: expanded, perRow: perRow)
        for (row, cells) in rows.enumerated() {
            if let column = cells.firstIndex(of: .tab(TabID(rawValue: "w1:tNEW"))) { return (row, column) }
        }
        return nil
    }

    private func assertPlaceholderMatchesTheLanding(tabs list: [TabID], expanded: Bool, closing: TabID? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let placeholder = placeholderSlot(tabs: list, expanded: expanded, closing: closing)
        let landing = landingSlot(tabs: list, expanded: expanded, closing: closing)
        XCTAssertNotNil(placeholder, "no placeholder drawn", file: file, line: line)
        XCTAssertNotNil(landing, "the tab is not drawn after the drop", file: file, line: line)
        XCTAssertEqual(placeholder?.row, landing?.row, file: file, line: line)
        XCTAssertEqual(placeholder?.column, landing?.column, file: file, line: line)
    }

    /// A resting card under its cap: the drop draws the tab, and the
    /// placeholder has to be standing in exactly that slot.
    func testThePlaceholderTakesTheSlotTheTabWillTakeOnARestingCard() {
        assertPlaceholderMatchesTheLanding(tabs: tabs(2), expanded: false)
        assertPlaceholderMatchesTheLanding(tabs: tabs(3), expanded: false)
    }

    /// An expanded card draws every tab, so the placeholder is exact at any
    /// count. Nine tabs plus the collapse tile is where appending used to put
    /// it one column late.
    func testThePlaceholderTakesTheSlotTheTabWillTakeOnAnExpandedCard() {
        assertPlaceholderMatchesTheLanding(tabs: tabs(9), expanded: true)
        assertPlaceholderMatchesTheLanding(tabs: tabs(5), expanded: true)
    }

    /// A tile always ends the list, so the slot after it is one no tab can
    /// ever reach. Wherever a placeholder and a tile are drawn together, the
    /// placeholder takes the tile's slot and the tile moves along.
    func testThePlaceholderIsOrderedBeforeTheTrailingTile() {
        let all = tabs(9)
        XCTAssertEqual(GridCardLayout.cells(tabs: all, expanded: true, newTab: true, perRow: perRow).suffix(2), [.newTab, .collapse])
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(5), expanded: true, newTab: true, perRow: perRow).suffix(2), [.newTab, .collapse])
        XCTAssertFalse(
            GridCardLayout.cells(tabs: all, expanded: true, newTab: true, perRow: perRow).contains { $0.isTile && $0 != .collapse },
            "the collapse tile is the only tile an expanded card draws"
        )
    }

    /// A resting card whose tabs already fill the row grows a tile instead of
    /// drawing the tab. Rather than open a row the drop will not leave
    /// behind, it shows nothing and lets the card's accent outline carry the
    /// affordance.
    func testARestingCardThatWillHideTheNewTabShowsNoPlaceholder() {
        XCTAssertNil(landingSlot(tabs: tabs(4), expanded: false), "the fifth tab really is hidden after the drop")
        XCTAssertNil(placeholderSlot(tabs: tabs(4), expanded: false))
        XCTAssertEqual(
            GridCardLayout.rows(tabs: tabs(4), expanded: false, newTab: true, perRow: perRow).count, 1,
            "and the card keeps the single row it already had"
        )
    }

    /// Already over the cap, so the card draws three tabs and a tile in one
    /// row and redraws to the same single row however many tabs it gains.
    /// Putting the placeholder in the tile's slot would push the tile into a
    /// second row that the drop takes straight back.
    func testARestingCardOverItsCapShowsNoPlaceholder() {
        XCTAssertNil(landingSlot(tabs: tabs(9), expanded: false), "the tenth tab really is hidden after the drop")
        XCTAssertNil(placeholderSlot(tabs: tabs(9), expanded: false))
        XCTAssertEqual(
            GridCardLayout.cells(tabs: tabs(9), expanded: false, newTab: true, perRow: perRow),
            GridCardLayout.cells(tabs: tabs(9), expanded: false, perRow: perRow),
            "the hovered card draws exactly what it drew at rest"
        )
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(9), expanded: false, newTab: true, perRow: perRow).count, 1)
    }

    /// The row an expanded card gains is one it keeps, so suppressing every
    /// added row would be wrong: seven tabs plus the collapse tile fill two
    /// rows exactly, and the drop really does open a third.
    func testAnExpandedCardStillOpensARowTheDropWillKeep() {
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(7), expanded: true, perRow: perRow).count, 2)
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(7), expanded: true, newTab: true, perRow: perRow).count, 3)
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(8), expanded: true, perRow: perRow).count, 3, "and the drop keeps it")
        assertPlaceholderMatchesTheLanding(tabs: tabs(7), expanded: true)
    }

    /// The whole rule, over every card shape: a preview may never stand in
    /// more rows than the card has once the drop lands, and wherever a
    /// placeholder IS drawn it stands in the slot the tab really takes.
    func testThePreviewNeverOpensARowTheDropWillNotLeaveBehind() {
        for count in 0...12 {
            for expanded in [false, true] {
                let previewed = GridCardLayout.rows(tabs: tabs(count), expanded: expanded, newTab: true, perRow: perRow).count
                let afterDrop = GridCardLayout.rows(tabs: tabs(count + 1), expanded: expanded, perRow: perRow).count
                XCTAssertLessThanOrEqual(previewed, afterDrop, "\(count) tabs, expanded: \(expanded)")
                guard placeholderSlot(tabs: tabs(count), expanded: expanded) != nil else { continue }
                assertPlaceholderMatchesTheLanding(tabs: tabs(count), expanded: expanded)
            }
        }
    }

    // MARK: - a drop that empties one of the card's own tabs

    /// The three ways a pane can arrive in a card's empty space. Every tab
    /// the card is drawing stays exactly where it is in all three, the tab
    /// the drop empties included: a card is what the user is aiming at, and a
    /// preview that takes one of its tabs away takes away the thing being
    /// aimed at.
    func testEveryDrawnTabKeepsItsSlotWhateverTheDropEmpties() {
        let all = tabs(3)
        let standing: [GridCell] = [.tab(all[0]), .tab(all[1]), .tab(all[2]), .newTab]
        for closing in [nil, all[0], all[2]] as [TabID?] {
            XCTAssertEqual(
                GridCardLayout.cells(tabs: all, expanded: false, newTab: true, closing: closing, perRow: perRow),
                standing, "closing: \(String(describing: closing))"
            )
        }
    }

    /// The user's own case: a card of one tab, whose only pane is the one
    /// being dragged. The tab it came from stays drawn in its own slot, so
    /// there is still something to drop back onto, and the placeholder takes
    /// the free slot beside it.
    func testACardOfOneTabKeepsThatTabAndPutsThePlaceholderBesideIt() {
        let only = tabs(1)
        XCTAssertEqual(
            GridCardLayout.cells(tabs: only, expanded: false, newTab: true, closing: only[0], perRow: perRow),
            [.tab(only[0]), .newTab]
        )
        XCTAssertEqual(placeholderSlot(tabs: only, expanded: false, closing: only[0])?.column, 1)
    }

    /// The whole rule, over every card shape. A card whose last row still has
    /// a free slot keeps every drawn cell exactly where it is and spends that
    /// one slot on the placeholder; only a card whose row is full falls back
    /// to the post-drop shape, which is the one path that may take the
    /// emptied tab away. A tile stays last either way.
    func testAFreeSlotKeepsEveryDrawnCellAndOnlyAFullRowFallsBack() {
        let created = TabID(rawValue: "w1:tNEW")
        for count in 1...12 {
            for expanded in [false, true] {
                let list = tabs(count)
                for closing in [nil, list[0], list[count - 1]] as [TabID?] {
                    let drawn = GridCardLayout.cells(tabs: list, expanded: expanded, perRow: perRow)
                    let preview = GridCardLayout.cells(
                        tabs: list, expanded: expanded, newTab: true, closing: closing, perRow: perRow
                    )
                    let shape = "\(count) tabs, expanded: \(expanded), closing: \(String(describing: closing))"
                    guard preview.contains(.newTab) else {
                        XCTAssertEqual(preview, drawn, "a card with no placeholder must be left as it stands: \(shape)")
                        continue
                    }
                    XCTAssertFalse(preview.dropLast().contains { $0.isTile }, "a tile did not stay last: \(shape)")
                    if drawn.count.isMultiple(of: perRow) {
                        XCTAssertEqual(
                            preview.map { $0 == .newTab ? GridCell.tab(created) : $0 },
                            GridCardLayout.cells(
                                tabs: GridCardLayout.surviving(list, closing: closing) + [created],
                                expanded: expanded, perRow: perRow
                            ),
                            "a full row must fall back to the card the drop leaves behind: \(shape)"
                        )
                        continue
                    }
                    XCTAssertEqual(preview.count, drawn.count + 1, "the preview cost more than one cell: \(shape)")
                    XCTAssertEqual(
                        preview.filter { $0 != .newTab }, drawn,
                        "a drawn cell moved, changed or vanished for a card with a free slot: \(shape)"
                    )
                }
            }
        }
    }

    /// A preview only ever adds to the row the card's cells already end on.
    /// When that row is full the card falls back to the post-drop shape, which
    /// is the only way a placeholder can still be drawn there.
    func testAFullRowFallsBackToThePostDropShape() {
        // Seven tabs and the collapse tile fill two rows exactly, so there is
        // no free slot and the post-drop shape opens the third row the drop
        // really leaves behind.
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(7), expanded: true, perRow: perRow).count, 8)
        let full = GridCardLayout.cells(tabs: tabs(7), expanded: true, newTab: true, perRow: perRow)
        XCTAssertEqual(full.suffix(2), [.newTab, .collapse])
        XCTAssertEqual(GridCardLayout.rows(full, perRow: perRow).count, 3)
        assertPlaceholderMatchesTheLanding(tabs: tabs(7), expanded: true)

        // A resting card at the cap has a full row and a post-drop shape that
        // hides the created tab, so it previews nothing at all.
        XCTAssertEqual(
            GridCardLayout.cells(tabs: tabs(4), expanded: false, newTab: true, perRow: perRow),
            GridCardLayout.cells(tabs: tabs(4), expanded: false, perRow: perRow)
        )
    }

    /// Where the placeholder and the landing slot disagree, and why. With no
    /// tab closing they are the same slot at every shape; when the drop
    /// empties one of the card's own tabs the created tab really lands in the
    /// slot that tab vacates, one earlier than the free slot the preview uses.
    /// The user asked for the tabs to stay put, so the preview keeps the free
    /// slot and the created tab moves back one when the drop lands.
    func testThePlaceholderIsTheLandingSlotUnlessTheDropEmptiesATab() {
        for count in 1...12 {
            for expanded in [false, true] {
                guard placeholderSlot(tabs: tabs(count), expanded: expanded) != nil else { continue }
                assertPlaceholderMatchesTheLanding(tabs: tabs(count), expanded: expanded)
            }
        }
        let all = tabs(3)
        XCTAssertEqual(placeholderSlot(tabs: all, expanded: false, closing: all[0])?.column, 3)
        XCTAssertEqual(landingSlot(tabs: all, expanded: false, closing: all[0])?.column, 2)
    }

    /// A card that cannot draw the created tab is left exactly as it stands,
    /// emptied tab included: its tile carries the drop instead, and nothing
    /// slides for a shape the drop does not leave behind.
    func testACardThatDrawsNoPlaceholderKeepsTheTabTheDropWillEmpty() {
        let all = tabs(9)
        XCTAssertEqual(
            GridCardLayout.cells(tabs: all, expanded: false, newTab: true, closing: all[0], perRow: perRow),
            GridCardLayout.cells(tabs: all, expanded: false, perRow: perRow)
        )
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: all, expanded: false, closing: all[0], perRow: perRow))
    }

    // MARK: - what a card that draws no placeholder previews instead

    /// The tile's hidden count is the one thing a drop on such a card
    /// visibly changes, so the tile carries the preview the placeholder
    /// cannot.
    func testARestingCardOverItsCapPreviewsTheDropOnItsTile() {
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(9), expanded: false, perRow: perRow))
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(5), expanded: false, perRow: perRow))
    }

    /// Which cards put the tab a drop creates on their trailing tile, which
    /// is what makes that tile the drop's own slot while the drag is live.
    /// A resting card over its cap has nowhere else to draw it. An expanded
    /// card ALWAYS has somewhere (its rows are the rows the drop leaves), so
    /// its collapse tile is never asked to carry one. A card with a free slot
    /// spends that slot and leaves its tile alone.
    func testOnlyACardWithNoSlotForTheTabPutsItOnItsTile() {
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(9), expanded: false, perRow: perRow))
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(5), expanded: false, perRow: perRow))
        for count in 5...16 {
            XCTAssertFalse(
                GridCardLayout.tilePreviewsTheDrop(tabs: tabs(count), expanded: true, perRow: perRow),
                "\(count) expanded: an expanded card has a slot for the tab, so its collapse tile is never the drop's"
            )
            XCTAssertTrue(
                GridCardLayout.cells(tabs: tabs(count), expanded: true, newTab: true, perRow: perRow).contains(.newTab),
                "\(count) expanded: and that slot has to be a real one"
            )
        }
        XCTAssertFalse(
            GridCardLayout.tilePreviewsTheDrop(tabs: tabs(3), expanded: false, perRow: perRow),
            "a card with a free slot"
        )
        XCTAssertTrue(GridCardLayout.cells(tabs: tabs(3), expanded: false, newTab: true, perRow: perRow).contains(.newTab))
    }

    /// A card that draws the tab needs no stand-in, and a card with no tile
    /// has nothing that could carry one.
    func testEveryOtherCardPreviewsNothingOnATile() {
        XCTAssertFalse(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(4), expanded: false, perRow: perRow), "at the cap, but no tile to wash")
        XCTAssertFalse(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(2), expanded: false, perRow: perRow), "draws the tab itself")
        XCTAssertFalse(GridCardLayout.tilePreviewsTheDrop(tabs: tabs(9), expanded: true, perRow: perRow), "draws the tab itself")
    }

    /// The two previews are alternatives, never both and never a card left
    /// with neither while it still has a tile to say something with.
    func testACardPreviewsOnItsTileExactlyWhenItDrawsNoPlaceholder() {
        for count in 0...12 {
            for expanded in [false, true] {
                let drawsPlaceholder = GridCardLayout.cells(tabs: tabs(count), expanded: expanded, newTab: true, perRow: perRow)
                    .contains(.newTab)
                let tilePreviews = GridCardLayout.tilePreviewsTheDrop(tabs: tabs(count), expanded: expanded, perRow: perRow)
                XCTAssertFalse(drawsPlaceholder && tilePreviews, "\(count) tabs, expanded: \(expanded)")
                if GridCardLayout.hasTile(tabs: count, perRow: perRow) {
                    XCTAssertTrue(drawsPlaceholder || tilePreviews, "\(count) tabs, expanded: \(expanded)")
                }
            }
        }
    }

    /// The row arithmetic the rule weighs is a second statement of what
    /// `cells` builds, so the two are checked against each other rather than
    /// left to drift.
    func testTheSettledCountAgreesWithTheCellsItStandsFor() {
        for count in 0...12 {
            for expanded in [false, true] {
                let built = GridCardLayout.cells(tabs: tabs(count), expanded: expanded, perRow: perRow)
                XCTAssertEqual(
                    GridCardLayout.settledCount(tabs: count, expanded: expanded, perRow: perRow), built.count,
                    "\(count) tabs, expanded: \(expanded)"
                )
                XCTAssertEqual(
                    GridCardLayout.rowCount(built.count, perRow: perRow),
                    GridCardLayout.rows(tabs: tabs(count), expanded: expanded, perRow: perRow).count,
                    "\(count) tabs, expanded: \(expanded)"
                )
            }
        }
    }

    func testCardsPairUpTwoToARowInRailOrder() {
        XCTAssertEqual(GridCardLayout.cardRows([1, 2, 3, 4, 5]), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(GridCardLayout.cardRows([Int]()), [])
    }

    // MARK: - grid state

    func testClosingForgetsExpandedCardsTheCardAndAPendingWait() {
        var state = AllWorkspacesGridState()
        state.open()
        state.toggleExpanded(w1)
        state.hoverMoved(pane: p1, pointer: .zero)
        state.hoverIntentElapsed(pane: p1)
        state.hoverMoved(pane: p2, pointer: .zero)
        state.close()
        XCTAssertFalse(state.isShown)
        XCTAssertEqual(state.expanded, [])
        XCTAssertNil(state.hover)
        state.open()
        state.hoverIntentElapsed(pane: p2)
        XCTAssertNil(state.hover, "a wait from before the grid closed must not show a card")
        XCTAssertEqual(state.expanded, [], "a grid opened again starts at rest")
    }

    func testToggleExpandedFoldsACardBack() {
        var state = AllWorkspacesGridState()
        state.toggleExpanded(w1)
        XCTAssertEqual(state.expanded, [w1])
        state.toggleExpanded(w1)
        XCTAssertEqual(state.expanded, [])
    }

    func testRetainForgetsAClosedWorkspacesExpansion() {
        var state = AllWorkspacesGridState()
        state.toggleExpanded(w1)
        state.toggleExpanded(w2)
        state.retain([w2])
        XCTAssertEqual(state.expanded, [w2])
    }

    // MARK: - hover intent

    func testACardShowsOnlyOnceThePointerHasRestedThroughTheWait() {
        var state = AllWorkspacesGridState()
        XCTAssertTrue(state.hoverMoved(pane: p1, pointer: CGPoint(x: 10, y: 20)), "entering a pane starts a wait")
        XCTAssertNil(state.hoverCard(dragInFlight: false))
        state.hoverIntentElapsed(pane: p1)
        XCTAssertEqual(state.hoverCard(dragInFlight: false), .init(pane: p1, pointer: CGPoint(x: 10, y: 20)))
    }

    func testLeavingBeforeTheWaitEndsShowsNothing() {
        var state = AllWorkspacesGridState()
        state.hoverMoved(pane: p1, pointer: .zero)
        state.hoverEnded(pane: p1)
        state.hoverIntentElapsed(pane: p1)
        XCTAssertNil(state.hoverCard(dragInFlight: false))
    }

    /// Crossing three panes starts three waits, and only the pane the pointer
    /// stopped on ever shows: the first two waits end on panes already left.
    func testASweepShowsOnlyThePaneThePointerStoppedOn() {
        var state = AllWorkspacesGridState()
        XCTAssertTrue(state.hoverMoved(pane: p1, pointer: .zero))
        XCTAssertTrue(state.hoverMoved(pane: p2, pointer: .zero))
        XCTAssertTrue(state.hoverMoved(pane: p3, pointer: .zero))
        state.hoverIntentElapsed(pane: p1)
        state.hoverIntentElapsed(pane: p2)
        XCTAssertNil(state.hoverCard(dragInFlight: false))
        state.hoverIntentElapsed(pane: p3)
        XCTAssertEqual(state.hoverCard(dragInFlight: false)?.pane, p3)
    }

    func testMovingWithinAPaneFollowsThePointerWithoutRestartingTheWait() {
        var state = AllWorkspacesGridState()
        state.hoverMoved(pane: p1, pointer: CGPoint(x: 1, y: 1))
        XCTAssertFalse(state.hoverMoved(pane: p1, pointer: CGPoint(x: 5, y: 5)))
        state.hoverIntentElapsed(pane: p1)
        XCTAssertEqual(state.hover?.pointer, CGPoint(x: 5, y: 5))
        XCTAssertFalse(state.hoverMoved(pane: p1, pointer: CGPoint(x: 9, y: 7)))
        XCTAssertEqual(state.hoverCard(dragInFlight: false)?.pointer, CGPoint(x: 9, y: 7), "the showing card follows the pointer")
    }

    func testMovingOntoANeighborHidesTheCardUntilTheNeighborsOwnWaitEnds() {
        var state = AllWorkspacesGridState()
        state.hoverMoved(pane: p1, pointer: .zero)
        state.hoverIntentElapsed(pane: p1)
        XCTAssertTrue(state.hoverMoved(pane: p2, pointer: .zero))
        XCTAssertNil(state.hoverCard(dragInFlight: false))
        state.hoverIntentElapsed(pane: p2)
        XCTAssertEqual(state.hoverCard(dragInFlight: false)?.pane, p2)
    }

    func testLeavingAPaneAfterItsNeighborWasEnteredKeepsTheNeighborsWait() {
        var state = AllWorkspacesGridState()
        state.hoverMoved(pane: p1, pointer: .zero)
        state.hoverMoved(pane: p2, pointer: .zero)
        state.hoverEnded(pane: p1)
        state.hoverIntentElapsed(pane: p2)
        XCTAssertEqual(state.hover?.pane, p2)
        state.hoverEnded(pane: p2)
        XCTAssertNil(state.hover)
    }

    func testTheHoverCardNeverShowsWhileADragIsInFlight() {
        var state = AllWorkspacesGridState()
        state.hoverMoved(pane: p1, pointer: .zero)
        state.hoverIntentElapsed(pane: p1)
        XCTAssertEqual(state.hoverCard(dragInFlight: false)?.pane, p1)
        XCTAssertNil(state.hoverCard(dragInFlight: true))
    }

    func testADragBeginningForgetsTheCardAndTheWait() {
        var state = AllWorkspacesGridState()
        state.hoverMoved(pane: p1, pointer: .zero)
        state.hoverIntentElapsed(pane: p1)
        state.hoverMoved(pane: p2, pointer: .zero)
        state.dragBegan()
        state.hoverIntentElapsed(pane: p2)
        XCTAssertNil(state.hoverCard(dragInFlight: false))
    }

    // MARK: - spring-load targets

    func testDwellingOnAPlusTileExpandsThatCardOnly() {
        var state = AllWorkspacesGridState()
        state.open()
        state.springLoaded(.moreTabs(w2))
        XCTAssertEqual(state.expanded, [w2])
    }

    /// A grid drag stays in the grid: resting on a thumbnail or a card must
    /// not hand the window back mid-drag.
    func testNoDwellInsideAShownGridClosesIt() {
        var state = AllWorkspacesGridState()
        state.open()
        state.springLoaded(.tabThumbnail(TabID(rawValue: "w2:t1")))
        state.springLoaded(.workspaceThumbnail(w2))
        XCTAssertTrue(state.isShown)
        XCTAssertTrue(state.expanded.isEmpty)
    }

    func testDwellsOutsideTheGridLeaveItAlone() {
        var state = AllWorkspacesGridState()
        state.springLoaded(.tabThumbnail(TabID(rawValue: "w1:t2")))
        state.springLoaded(.moreTabs(w1))
        state.springLoaded(.workspaceThumbnail(w2))
        XCTAssertEqual(state, AllWorkspacesGridState(), "a strip thumbnail or a rail row dwell must not open or expand anything")
    }

    // MARK: - Esc

    func testALiveDragAlwaysOwnsEsc() {
        for grid in [false, true] {
            for rail in [false, true] {
                XCTAssertEqual(EscapeRoute.route(dragIdle: false, gridShown: grid, railTakesEscape: rail), .drag)
            }
        }
    }

    func testAnIdleEscClosesAShownGridBeforeTheRailSelectionSeesIt() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, railTakesEscape: true), .grid)
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, railTakesEscape: false), .grid)
    }

    func testWithNoGridEscIsTheRailsOrTheTerminals() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: false, railTakesEscape: true), .railSelection)
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: false, railTakesEscape: false), .focusedView)
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
