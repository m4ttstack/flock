import CoreGraphics
import XCTest
@testable import PaddockCore

final class AllWorkspacesGridTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")
    private let p1 = PaneID(rawValue: "w1:p1")
    private let p2 = PaneID(rawValue: "w1:p2")
    private let p3 = PaneID(rawValue: "w1:p3")

    private func tabs(_ count: Int) -> [TabID] {
        (1...max(count, 1)).prefix(count).map { TabID(rawValue: "w1:t\($0)") }
    }

    // MARK: - card layout

    func testACardOfFourOrFewerTabsShowsThemAllWithNoTile() {
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(1), expanded: false), tabs(1).map(GridCell.tab))
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(4), expanded: false), tabs(4).map(GridCell.tab))
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(4), expanded: true), tabs(4).map(GridCell.tab), "nothing is hidden, so there is nothing to expand or collapse")
    }

    func testARestingCardOfFiveTabsShowsThreeAndATileForTheOtherTwo() {
        let all = tabs(5)
        XCTAssertEqual(GridCardLayout.cells(tabs: all, expanded: false), [.tab(all[0]), .tab(all[1]), .tab(all[2]), .moreTabs(hidden: 2)])
    }

    func testARestingCardOfNineTabsIsOneRowEndingInPlusSix() {
        let rows = GridCardLayout.rows(tabs: tabs(9), expanded: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].last, .moreTabs(hidden: 6))
    }

    func testAnExpandedCardShowsEveryTabFourPerRowThenTheCollapseTile() {
        let all = tabs(9)
        let rows = GridCardLayout.rows(tabs: all, expanded: true)
        XCTAssertEqual(rows.map(\.count), [4, 4, 2])
        XCTAssertEqual(rows.flatMap { $0 }, all.map(GridCell.tab) + [.collapse])
    }

    func testAnExpandedCardWhoseTabsAndTileFillRowsExactlyAddsNoEmptyRow() {
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(7), expanded: true).map(\.count), [4, 4])
    }

    // MARK: - the new-tab placeholder's slot

    /// Where the placeholder actually lands, read off the card's own rows --
    /// the same rows the card draws, so nothing here is a parallel model of
    /// the geometry.
    private func placeholderSlot(tabs list: [TabID], expanded: Bool, closing: TabID? = nil) -> (row: Int, column: Int)? {
        let rows = GridCardLayout.rows(GridCardLayout.cells(tabs: list, expanded: expanded, newTab: true, closing: closing))
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
        let rows = GridCardLayout.rows(tabs: added, expanded: expanded)
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
        XCTAssertEqual(GridCardLayout.cells(tabs: all, expanded: true, newTab: true).suffix(2), [.newTab, .collapse])
        XCTAssertEqual(GridCardLayout.cells(tabs: tabs(5), expanded: true, newTab: true).suffix(2), [.newTab, .collapse])
        XCTAssertFalse(
            GridCardLayout.cells(tabs: all, expanded: true, newTab: true).contains { $0.isTile && $0 != .collapse },
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
            GridCardLayout.rows(tabs: tabs(4), expanded: false, newTab: true).count, 1,
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
            GridCardLayout.cells(tabs: tabs(9), expanded: false, newTab: true),
            GridCardLayout.cells(tabs: tabs(9), expanded: false),
            "the hovered card draws exactly what it drew at rest"
        )
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(9), expanded: false, newTab: true).count, 1)
    }

    /// The row an expanded card gains is one it keeps, so suppressing every
    /// added row would be wrong: seven tabs plus the collapse tile fill two
    /// rows exactly, and the drop really does open a third.
    func testAnExpandedCardStillOpensARowTheDropWillKeep() {
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(7), expanded: true).count, 2)
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(7), expanded: true, newTab: true).count, 3)
        XCTAssertEqual(GridCardLayout.rows(tabs: tabs(8), expanded: true).count, 3, "and the drop keeps it")
        assertPlaceholderMatchesTheLanding(tabs: tabs(7), expanded: true)
    }

    /// The whole rule, over every card shape: a preview may never stand in
    /// more rows than the card has once the drop lands, and wherever a
    /// placeholder IS drawn it stands in the slot the tab really takes.
    func testThePreviewNeverOpensARowTheDropWillNotLeaveBehind() {
        for count in 0...12 {
            for expanded in [false, true] {
                let previewed = GridCardLayout.rows(tabs: tabs(count), expanded: expanded, newTab: true).count
                let afterDrop = GridCardLayout.rows(tabs: tabs(count + 1), expanded: expanded).count
                XCTAssertLessThanOrEqual(previewed, afterDrop, "\(count) tabs, expanded: \(expanded)")
                guard placeholderSlot(tabs: tabs(count), expanded: expanded) != nil else { continue }
                assertPlaceholderMatchesTheLanding(tabs: tabs(count), expanded: expanded)
            }
        }
    }

    // MARK: - a drop that empties one of the card's own tabs

    /// The three ways a pane can arrive in a card's empty space. A pane from
    /// another workspace and a pane from a multi-pane tab of this one leave
    /// every tab standing; the last pane of a tab of this one takes that tab
    /// with it. All three land a tab in this card, so all three draw the
    /// placeholder, and the pane's origin is not what decides it.
    func testAPaneLandsATabInThisCardWhereverItCameFrom() {
        let all = tabs(3)
        let fromElsewhere = GridCardLayout.cells(tabs: all, expanded: false, newTab: true, closing: nil)
        XCTAssertEqual(fromElsewhere, [.tab(all[0]), .tab(all[1]), .tab(all[2]), .newTab])
        XCTAssertEqual(
            GridCardLayout.cells(tabs: all, expanded: false, newTab: true, closing: all[0]),
            [.tab(all[1]), .tab(all[2]), .newTab],
            "the tab the drop empties is gone, and the created one takes the slot it leaves"
        )
        XCTAssertNotNil(placeholderSlot(tabs: all, expanded: false, closing: all[0]))
    }

    /// The slot the placeholder names is the slot the created tab really
    /// takes once the emptied one is gone, at every shape a card can have.
    func testThePlaceholderTakesTheLandingSlotWhenTheDropEmptiesATab() {
        for count in 1...12 {
            for expanded in [false, true] {
                let list = tabs(count)
                for closing in [list[0], list[count - 1]] {
                    guard placeholderSlot(tabs: list, expanded: expanded, closing: closing) != nil else { continue }
                    assertPlaceholderMatchesTheLanding(tabs: list, expanded: expanded, closing: closing)
                }
            }
        }
    }

    /// A card whose only tab is the one being emptied ends the drop with one
    /// tab again, in the slot that tab holds now.
    func testACardOfOneTabPreviewsTheDropInThatTabsOwnSlot() {
        let only = tabs(1)
        XCTAssertEqual(GridCardLayout.cells(tabs: only, expanded: false, newTab: true, closing: only[0]), [.newTab])
        assertPlaceholderMatchesTheLanding(tabs: only, expanded: false, closing: only[0])
    }

    /// Wherever a placeholder is drawn at all, the preview is the card the
    /// drop leaves behind, cell for cell, with the created tab drawn as the
    /// placeholder: the tabs that survive, the trailing tile the post-drop
    /// count calls for, and nothing else. Over every shape, with and without
    /// one of the card's own tabs closing.
    func testAPreviewDrawsTheCardTheDropLeavesBehind() {
        let created = TabID(rawValue: "w1:tNEW")
        for count in 1...12 {
            for expanded in [false, true] {
                let list = tabs(count)
                for closing in [nil, list[0], list[count - 1]] as [TabID?] {
                    let preview = GridCardLayout.cells(tabs: list, expanded: expanded, newTab: true, closing: closing)
                    guard preview.contains(.newTab) else { continue }
                    let afterTheDrop = GridCardLayout.cells(
                        tabs: GridCardLayout.surviving(list, closing: closing) + [created], expanded: expanded
                    )
                    XCTAssertEqual(
                        preview.map { $0 == .newTab ? GridCell.tab(created) : $0 }, afterTheDrop,
                        "\(count) tabs, expanded: \(expanded), closing: \(String(describing: closing))"
                    )
                }
            }
        }
    }

    /// A drop that empties one of the card's own tabs costs the card no cell:
    /// the created tab takes the slot the emptied one leaves, which is what
    /// lets the placeholder be drawn inside the rows the card already has.
    func testAPreviewForADropThatEmptiesATabCostsTheCardNoCell() {
        for count in 1...12 {
            for expanded in [false, true] {
                let list = tabs(count)
                XCTAssertEqual(
                    GridCardLayout.cells(tabs: list, expanded: expanded, newTab: true, closing: list[0]).count,
                    GridCardLayout.cells(tabs: list, expanded: expanded).count,
                    "\(count) tabs, expanded: \(expanded)"
                )
            }
        }
    }

    /// A card that cannot draw the created tab is left exactly as it stands,
    /// emptied tab included: its tile carries the drop instead, and nothing
    /// slides for a shape the drop does not leave behind.
    func testACardThatDrawsNoPlaceholderKeepsTheTabTheDropWillEmpty() {
        let all = tabs(9)
        XCTAssertEqual(
            GridCardLayout.cells(tabs: all, expanded: false, newTab: true, closing: all[0]),
            GridCardLayout.cells(tabs: all, expanded: false)
        )
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: GridCardLayout.surviving(all, closing: all[0]).count, expanded: false))
    }

    // MARK: - what a card that draws no placeholder previews instead

    /// The tile's hidden count is the one thing a drop on such a card
    /// visibly changes, so the tile carries the preview the placeholder
    /// cannot.
    func testARestingCardOverItsCapPreviewsTheDropOnItsTile() {
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: 9, expanded: false))
        XCTAssertTrue(GridCardLayout.tilePreviewsTheDrop(tabs: 5, expanded: false))
    }

    /// A card that draws the tab needs no stand-in, and a card with no tile
    /// has nothing that could carry one.
    func testEveryOtherCardPreviewsNothingOnATile() {
        XCTAssertFalse(GridCardLayout.tilePreviewsTheDrop(tabs: 4, expanded: false), "at the cap, but no tile to wash")
        XCTAssertFalse(GridCardLayout.tilePreviewsTheDrop(tabs: 2, expanded: false), "draws the tab itself")
        XCTAssertFalse(GridCardLayout.tilePreviewsTheDrop(tabs: 9, expanded: true), "draws the tab itself")
    }

    /// The two previews are alternatives, never both and never a card left
    /// with neither while it still has a tile to say something with.
    func testACardPreviewsOnItsTileExactlyWhenItDrawsNoPlaceholder() {
        for count in 0...12 {
            for expanded in [false, true] {
                let drawsPlaceholder = GridCardLayout.cells(tabs: tabs(count), expanded: expanded, newTab: true)
                    .contains(.newTab)
                let tilePreviews = GridCardLayout.tilePreviewsTheDrop(tabs: count, expanded: expanded)
                XCTAssertFalse(drawsPlaceholder && tilePreviews, "\(count) tabs, expanded: \(expanded)")
                if GridCardLayout.hasTile(tabs: count) {
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
                let built = GridCardLayout.cells(tabs: tabs(count), expanded: expanded)
                XCTAssertEqual(
                    GridCardLayout.settledCount(tabs: count, expanded: expanded), built.count,
                    "\(count) tabs, expanded: \(expanded)"
                )
                XCTAssertEqual(
                    GridCardLayout.rowCount(built.count),
                    GridCardLayout.rows(tabs: tabs(count), expanded: expanded).count,
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
