import XCTest
@testable import FlockCore

final class LaunchTargetTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")

    func testAFocusedShellPaneIsTheTarget() {
        XCTAssertEqual(LaunchTarget.pane(canvasPane: pane, agent: nil), pane)
    }

    func testAPaneRunningAnAgentIsNoTarget() {
        XCTAssertNil(LaunchTarget.pane(canvasPane: pane, agent: "claude"))
        XCTAssertNil(LaunchTarget.pane(canvasPane: pane, agent: "codex"))
    }

    func testNoCanvasPaneIsNoTarget() {
        XCTAssertNil(LaunchTarget.pane(canvasPane: nil, agent: nil))
    }
}
