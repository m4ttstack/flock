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
