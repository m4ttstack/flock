import XCTest
@testable import FlockCore

final class ViewTabTests: XCTestCase {
    func testTabsAreInKeyOrder() {
        XCTAssertEqual(ViewTab.allCases, [.workspaces, .overview, .arrange])
        XCTAssertEqual(ViewTab.allCases.map(\.digit), ["1", "2", "3"])
        XCTAssertEqual(ViewTab.allCases.map(\.title), ["Workspaces", "Overview", "Arrange"])
    }

    func testWorkspacesWhileTheGridIsClosedWhateverModeIsRemembered() {
        XCTAssertEqual(ViewTab.selected(gridShown: false, shownMode: .missionControl), .workspaces)
        XCTAssertEqual(ViewTab.selected(gridShown: false, shownMode: .arrange), .workspaces)
    }

    func testTheShownModeOtherwise() {
        XCTAssertEqual(ViewTab.selected(gridShown: true, shownMode: .missionControl), .overview)
        XCTAssertEqual(ViewTab.selected(gridShown: true, shownMode: .arrange), .arrange)
    }

    func testOverviewAndArrangeOpenTheGridInTheirMode() {
        XCTAssertEqual(ViewTab.overview.steps(gridShown: false, focused: false, dragInFlight: false), [.select(.missionControl), .openGrid])
        XCTAssertEqual(ViewTab.arrange.steps(gridShown: false, focused: false, dragInFlight: false), [.select(.arrange), .openGrid])
        XCTAssertEqual(ViewTab.arrange.steps(gridShown: true, focused: false, dragInFlight: false), [.select(.arrange), .openGrid])
    }

    func testWorkspacesClosesTheGridAndIsANoOpWhenAlreadyThere() {
        XCTAssertEqual(ViewTab.workspaces.steps(gridShown: true, focused: false, dragInFlight: false), [.closeGrid])
        XCTAssertEqual(ViewTab.workspaces.steps(gridShown: true, focused: true, dragInFlight: false), [.closeGrid])
        XCTAssertEqual(ViewTab.workspaces.steps(gridShown: false, focused: false, dragInFlight: false), [])
    }

    func testAFocusedPaneBelongsToOverview() {
        XCTAssertEqual(ViewTab.overview.steps(gridShown: true, focused: true, dragInFlight: false), [])
        XCTAssertEqual(
            ViewTab.arrange.steps(gridShown: true, focused: true, dragInFlight: false),
            [.unfocus, .select(.arrange), .openGrid]
        )
    }

    func testNothingDuringADrag() {
        for tab in ViewTab.allCases {
            XCTAssertEqual(tab.steps(gridShown: true, focused: false, dragInFlight: true), [], "\(tab)")
            XCTAssertEqual(tab.steps(gridShown: false, focused: false, dragInFlight: true), [], "\(tab)")
        }
    }

    func testTheTitleShowsWhileItClearsBothEnds() {
        XCTAssertTrue(TitleBarFit.showsTitle(barWidth: 900, titleWidth: 40, leadingEdge: 380, trailingWidth: 120, gap: 12))
    }

    func testTheTitleHidesBeforeTheTabsReachIt() {
        XCTAssertFalse(TitleBarFit.showsTitle(barWidth: 760, titleWidth: 40, leadingEdge: 360, trailingWidth: 0, gap: 12))
        XCTAssertTrue(TitleBarFit.showsTitle(barWidth: 800, titleWidth: 40, leadingEdge: 368, trailingWidth: 0, gap: 12))
    }

    func testTheTitleHidesBeforeTheRightSideReachesIt() {
        XCTAssertFalse(TitleBarFit.showsTitle(barWidth: 900, titleWidth: 40, leadingEdge: 100, trailingWidth: 420, gap: 12))
    }
}
