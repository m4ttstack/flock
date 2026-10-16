import XCTest
@testable import FlockCore

final class RtLabelsTests: XCTestCase {
    func testTheSharedAndRunnerWorkspacesAreFlockOwnedAndNothingElse() {
        XCTAssertTrue(RtLabels.isFlockOwned(workspaceLabel: "flock:rt"))
        XCTAssertTrue(RtLabels.isFlockOwned(workspaceLabel: "flock:rt runner term_a1"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "acme"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "flock:rtx"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "my flock:rt"))
    }

    func testARunnerWorkspaceNamesItsTerminal() {
        XCTAssertEqual(RtLabels.runnerWorkspaceLabel(linkedTo: TerminalID(rawValue: "term_a1")), "flock:rt runner term_a1")
    }

    func testATabLabelRoundTrips() {
        let link = RtLabels.TabLink(kind: .run, terminal: TerminalID(rawValue: "term_18c2f0a1"), token: "3f2a")
        XCTAssertEqual(RtLabels.tabLabel(link), "run term_18c2f0a1 3f2a")
        XCTAssertEqual(RtLabels.tabLink(fromLabel: "run term_18c2f0a1 3f2a"), link)
    }

    func testATabLabelWithItsPaneRoundTrips() {
        let link = RtLabels.TabLink(
            kind: .runner, terminal: TerminalID(rawValue: "term_18c2f0a1"), token: "3f2a", pane: PaneID(rawValue: "wHH:p3W")
        )
        XCTAssertEqual(RtLabels.tabLabel(link), "runner term_18c2f0a1 3f2a wHH:p3W")
        XCTAssertEqual(RtLabels.tabLink(fromLabel: "runner term_18c2f0a1 3f2a wHH:p3W"), link)
    }

    func testALabelWithoutAPaneReadsAsALinkWithNone() {
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1 3f2a")?.pane)
    }

    func testAPaneIDALabelCannotHoldIsLeftOut() {
        let link = RtLabels.TabLink(kind: .run, terminal: TerminalID(rawValue: "term_a1"), token: "3f2a", pane: PaneID(rawValue: "w1 p1"))
        XCTAssertEqual(RtLabels.tabLabel(link), "run term_a1 3f2a")
    }

    func testAnythingElseIsNotALink() {
        XCTAssertNil(RtLabels.tabLink(fromLabel: "zsh"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "build term_a1 3f2a"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run  3f2a"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1 3f2a "))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1 3f2a w1:p1 extra"))
    }
}
