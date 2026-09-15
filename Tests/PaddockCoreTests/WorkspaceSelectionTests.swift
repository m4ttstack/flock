import CoreGraphics
import XCTest
@testable import PaddockCore

final class WorkspaceSelectionTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")
    private let w3 = WorkspaceID(rawValue: "w3")
    private var order: [WorkspaceID] { [w1, w2, w3] }

    /// Two rows Cmd+clicked, exactly as the app delivers it: the press on
    /// each row reaches the monitor before the tap toggles it.
    private func twoSelectedByCommandClick() -> WorkspaceSelection {
        var selection = WorkspaceSelection()
        _ = selection.click(w1, commandHeld: true)
        selection.pointerPressed(onRailRow: true)
        _ = selection.click(w3, commandHeld: true)
        return selection
    }

    // MARK: - clicks

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

    // MARK: - Esc belongs to the terminal unless the rail is in use

    func testEscapeAfterAPressIntoAPaneIsNeverTaken() {
        var selection = twoSelectedByCommandClick()
        selection.pointerPressed(onRailRow: false)
        XCTAssertFalse(selection.escapePressed(dragIdle: true))
    }

    func testAPressAnywhereOffTheRailRowsEndsTheSelection() {
        var selection = twoSelectedByCommandClick()
        selection.pointerPressed(onRailRow: false)
        XCTAssertTrue(selection.isEmpty)
    }

    func testAPressOnARailRowKeepsTheSelection() {
        var selection = twoSelectedByCommandClick()
        selection.pointerPressed(onRailRow: true)
        XCTAssertEqual(selection.ids, [w1, w3])
    }

    func testEscapeRightAfterSelectingIsTheRailsAndClears() {
        var selection = twoSelectedByCommandClick()
        XCTAssertTrue(selection.escapePressed(dragIdle: true))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.escapePressed(dragIdle: true), "a second Esc has nothing left to clear")
    }

    func testEscapeAfterTypingPassesThroughAndLeavesTheSelection() {
        var selection = twoSelectedByCommandClick()
        selection.disengage()
        XCTAssertFalse(selection.escapePressed(dragIdle: true))
        XCTAssertEqual(selection.ids, [w1, w3])
    }

    func testEscapeDuringALiveDragIsNeverTakenHere() {
        var selection = twoSelectedByCommandClick()
        XCTAssertFalse(selection.escapePressed(dragIdle: false))
        XCTAssertEqual(selection.ids, [w1, w3])
    }

    // MARK: - drags

    func testOnlyARailDragEndsTheSelection() {
        var selection = WorkspaceSelection(ids: [w1, w3])
        selection.dragFinished(.pane(PaneID(rawValue: "w1:p1")))
        selection.dragFinished(.tab(TabID(rawValue: "w1:t1")))
        XCTAssertEqual(selection.ids, [w1, w3])
        selection.dragFinished(.workspace(w2))
        XCTAssertTrue(selection.isEmpty)

        var block = WorkspaceSelection(ids: [w1, w3])
        block.dragFinished(.workspaces([w1, w3]))
        XCTAssertTrue(block.isEmpty)
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

    // MARK: - hit test

    func testRailRowHitTestSkipsRowsOutsideTheViewport() {
        let rows = [CGRect(x: 0, y: 40, width: 180, height: 27), CGRect(x: 0, y: 240, width: 180, height: 27)]
        let viewport = CGRect(x: 0, y: 30, width: 192, height: 200)
        XCTAssertTrue(WorkspaceSelection.isRailRow(CGPoint(x: 50, y: 50), rows: rows, viewport: viewport))
        XCTAssertFalse(WorkspaceSelection.isRailRow(CGPoint(x: 50, y: 250), rows: rows, viewport: viewport))
        XCTAssertFalse(WorkspaceSelection.isRailRow(CGPoint(x: 50, y: 100), rows: rows, viewport: viewport))
        XCTAssertTrue(WorkspaceSelection.isRailRow(CGPoint(x: 50, y: 250), rows: rows, viewport: nil))
    }
}
