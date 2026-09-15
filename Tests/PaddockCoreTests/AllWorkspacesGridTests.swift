import CoreGraphics
import XCTest
@testable import PaddockCore

final class AllWorkspacesGridTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")

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

    func testClosingForgetsExpandedCardsAndTheHover() {
        var state = AllWorkspacesGridState()
        state.open()
        state.toggleExpanded(w1)
        state.hoverBegan(pane: PaneID(rawValue: "w1:p1"), anchor: .zero)
        state.close()
        XCTAssertFalse(state.isShown)
        XCTAssertFalse(state.isExpanded(w1))
        XCTAssertNil(state.hover)
        state.open()
        XCTAssertFalse(state.isExpanded(w1), "a grid opened again starts at rest")
    }

    func testToggleExpandedFoldsACardBack() {
        var state = AllWorkspacesGridState()
        state.toggleExpanded(w1)
        XCTAssertTrue(state.isExpanded(w1))
        state.toggleExpanded(w1)
        XCTAssertFalse(state.isExpanded(w1))
    }

    func testRetainForgetsAClosedWorkspacesExpansion() {
        var state = AllWorkspacesGridState()
        state.toggleExpanded(w1)
        state.toggleExpanded(w2)
        state.retain([w2])
        XCTAssertEqual(state.expanded, [w2])
    }

    func testTheHoverCardNeverShowsWhileADragIsInFlight() {
        var state = AllWorkspacesGridState()
        let pane = PaneID(rawValue: "w1:p1")
        state.hoverBegan(pane: pane, anchor: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(state.hoverCard(dragInFlight: false)?.pane, pane)
        XCTAssertNil(state.hoverCard(dragInFlight: true))
    }

    func testADragBeginningForgetsTheHoverSoItDoesNotReturnWhenTheDragEnds() {
        var state = AllWorkspacesGridState()
        state.hoverBegan(pane: PaneID(rawValue: "w1:p1"), anchor: .zero)
        state.dragBegan()
        XCTAssertNil(state.hoverCard(dragInFlight: false))
    }

    func testLeavingAPaneAfterItsNeighborWasEnteredKeepsTheNeighbor() {
        var state = AllWorkspacesGridState()
        let first = PaneID(rawValue: "w1:p1")
        let neighbor = PaneID(rawValue: "w1:p2")
        state.hoverBegan(pane: first, anchor: .zero)
        state.hoverBegan(pane: neighbor, anchor: .zero)
        state.hoverEnded(pane: first)
        XCTAssertEqual(state.hover?.pane, neighbor)
        state.hoverEnded(pane: neighbor)
        XCTAssertNil(state.hover)
    }

    // MARK: - spring-load targets

    func testDwellingOnTheRailEntryOpensTheGrid() {
        var state = AllWorkspacesGridState()
        state.springLoaded(.allWorkspaces)
        XCTAssertTrue(state.isShown)
    }

    func testDwellingOnAPlusTileExpandsThatCardOnly() {
        var state = AllWorkspacesGridState()
        state.open()
        state.springLoaded(.moreTabs(w2))
        XCTAssertEqual(state.expanded, [w2])
    }

    func testDwellingOnAGridThumbnailHandsTheWindowBackToThatTab() {
        var state = AllWorkspacesGridState()
        state.open()
        state.springLoaded(.tabThumbnail(TabID(rawValue: "w2:t1")))
        XCTAssertFalse(state.isShown)
    }

    func testDwellsOutsideTheGridLeaveItAlone() {
        var state = AllWorkspacesGridState()
        state.springLoaded(.tabThumbnail(TabID(rawValue: "w1:t2")))
        state.springLoaded(.moreTabs(w1))
        state.springLoaded(.workspaceThumbnail(w2))
        XCTAssertEqual(state, AllWorkspacesGridState(), "a strip thumbnail or a rail row dwell must not open, close or expand anything")
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
        let pane = PaneID(rawValue: "w1:p1")
        XCTAssertTrue(requests.begin(pane: pane, revision: 3))
        XCTAssertFalse(requests.begin(pane: pane, revision: 3))
        XCTAssertTrue(requests.begin(pane: pane, revision: 4))
        XCTAssertTrue(requests.begin(pane: PaneID(rawValue: "w1:p2"), revision: 3), "revisions are per pane")
    }

    func testAReplyForARevisionThePaneHasMovedPastIsStale() {
        var requests = LastLineRequests()
        let pane = PaneID(rawValue: "w1:p1")
        _ = requests.begin(pane: pane, revision: 3)
        XCTAssertTrue(requests.accepts(pane: pane, revision: 3))
        _ = requests.begin(pane: pane, revision: 4)
        XCTAssertFalse(requests.accepts(pane: pane, revision: 3))
        XCTAssertTrue(requests.accepts(pane: pane, revision: 4))
        XCTAssertFalse(requests.accepts(pane: PaneID(rawValue: "w1:p9"), revision: 4), "a pane never asked for has nothing to accept")
    }
}
