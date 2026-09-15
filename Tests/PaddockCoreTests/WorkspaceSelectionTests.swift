import XCTest
@testable import PaddockCore

final class WorkspaceSelectionTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")
    private let w3 = WorkspaceID(rawValue: "w3")
    private var order: [WorkspaceID] { [w1, w2, w3] }

    func testPlainClickJumpsAndLeavesNothingSelected() {
        var selection = WorkspaceSelection()
        XCTAssertEqual(selection.click(w2, commandHeld: false), .jump(w2))
        XCTAssertTrue(selection.isEmpty)
    }

    func testCommandClickTogglesWithoutJumping() {
        var selection = WorkspaceSelection()
        XCTAssertEqual(selection.click(w1, commandHeld: true), .toggled)
        XCTAssertEqual(selection.click(w3, commandHeld: true), .toggled)
        XCTAssertEqual(selection.ids, [w1, w3])
        XCTAssertEqual(selection.click(w1, commandHeld: true), .toggled)
        XCTAssertEqual(selection.ids, [w3])
    }

    func testPlainClickClearsAnExistingSelectionAndStillJumps() {
        var selection = WorkspaceSelection(ids: [w1, w3])
        XCTAssertEqual(selection.click(w3, commandHeld: false), .jump(w3))
        XCTAssertTrue(selection.isEmpty)
    }

    func testDraggingASelectedRowCarriesTheWholeSelectionInRailOrder() {
        let selection = WorkspaceSelection(ids: [w3, w1])
        XCTAssertEqual(selection.dragSubject(pressing: w3, order: order), .workspaces([w1, w3]))
    }

    func testDraggingAnUnselectedRowIsTheSingleMove() {
        let selection = WorkspaceSelection(ids: [w1, w3])
        XCTAssertEqual(selection.dragSubject(pressing: w2, order: order), .workspace(w2))
    }

    func testASelectionOfOneDragsAsTheSingleMove() {
        let selection = WorkspaceSelection(ids: [w2])
        XCTAssertEqual(selection.dragSubject(pressing: w2, order: order), .workspace(w2))
    }

    func testRetainForgetsWorkspacesTheRailNoLongerHas() {
        var selection = WorkspaceSelection(ids: [w1, w2, w3])
        selection.retain([w1, w3])
        XCTAssertEqual(selection.ids, [w1, w3])
        XCTAssertEqual(selection.dragSubject(pressing: w1, order: [w1, w3]), .workspaces([w1, w3]))
    }

    func testEscapeClearsOnlyASelectionWhileNoDragIsLive() {
        XCTAssertTrue(WorkspaceSelection(ids: [w1]).escapeClears(dragIdle: true))
        XCTAssertFalse(WorkspaceSelection(ids: [w1]).escapeClears(dragIdle: false))
        XCTAssertFalse(WorkspaceSelection().escapeClears(dragIdle: true))
    }
}
