import CoreGraphics
import XCTest
@testable import PaddockCore

final class WorkspaceSelectionTests: XCTestCase {
    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")
    private let w3 = WorkspaceID(rawValue: "w3")
    private var order: [WorkspaceID] { [w1, w2, w3] }

    /// Two rows Cmd+clicked with no current row, exactly as the app delivers
    /// it: the press on each row reaches the monitor before the tap toggles it.
    private func twoSelectedByCommandClick() -> WorkspaceSelection {
        var selection = WorkspaceSelection()
        _ = selection.click(w1, commandHeld: true, current: nil, order: order)
        selection.pointerPressed(onRailRow: true)
        _ = selection.click(w3, commandHeld: true, current: nil, order: order)
        return selection
    }

    // MARK: - clicks

    func testPlainClickJumpsAndLeavesNothingSelected() {
        var selection = WorkspaceSelection()
        XCTAssertEqual(selection.click(w2, commandHeld: false, current: w1, order: order), .jump(w2))
        XCTAssertTrue(selection.isEmpty)
    }

    func testCommandClickTogglesWithoutJumping() {
        var selection = WorkspaceSelection()
        XCTAssertEqual(selection.click(w1, commandHeld: true, current: nil, order: order), .toggled)
        XCTAssertEqual(selection.click(w3, commandHeld: true, current: nil, order: order), .toggled)
        XCTAssertEqual(selection.ids, [w1, w3])
        XCTAssertEqual(selection.click(w1, commandHeld: true, current: nil, order: order), .toggled)
        XCTAssertEqual(selection.ids, [w3])
    }

    func testPlainClickClearsAnExistingSelectionAndStillJumps() {
        var selection = WorkspaceSelection(ids: [w1, w3])
        XCTAssertEqual(selection.click(w3, commandHeld: false, current: w1, order: order), .jump(w3))
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: - the Cmd+click that starts a selection takes herdr's current row along

    /// On w1, Cmd+click w2: w1 already shows the fill, so it is selected too.
    func testTheCommandClickThatStartsASelectionAlsoSelectsTheCurrentRow() {
        var selection = WorkspaceSelection()
        XCTAssertEqual(selection.click(w2, commandHeld: true, current: w1, order: order), .toggled)
        XCTAssertEqual(selection.ids, [w1, w2])
    }

    func testCommandClickingTheCurrentRowWithNothingSelectedSelectsOnlyIt() {
        var selection = WorkspaceSelection()
        _ = selection.click(w1, commandHeld: true, current: w1, order: order)
        XCTAssertEqual(selection.ids, [w1])
    }

    func testWithNoCurrentRowTheStartingCommandClickSelectsOnlyTheClickedRow() {
        var selection = WorkspaceSelection()
        _ = selection.click(w2, commandHeld: true, current: nil, order: order)
        XCTAssertEqual(selection.ids, [w2])
    }

    /// herdr's selected workspace was closed and the rail no longer lists it,
    /// but the view model still names it: it must not ride into the block.
    func testACurrentRowTheRailNoLongerListsIsNotSeeded() {
        var selection = WorkspaceSelection()
        let closed = WorkspaceID(rawValue: "w9")
        _ = selection.click(w2, commandHeld: true, current: closed, order: order)
        XCTAssertEqual(selection.ids, [w2])
        _ = selection.click(w3, commandHeld: true, current: closed, order: order)
        XCTAssertEqual(selection.dragSubject(pressing: w2, order: order), .workspaces([w2, w3]))
    }

    func testTheSeededCurrentRowTogglesOutAndIsNotSeededAgain() {
        var selection = WorkspaceSelection()
        _ = selection.click(w2, commandHeld: true, current: w1, order: order)
        _ = selection.click(w1, commandHeld: true, current: w1, order: order)
        XCTAssertEqual(selection.ids, [w2])
        _ = selection.click(w3, commandHeld: true, current: w1, order: order)
        XCTAssertEqual(selection.ids, [w2, w3], "a selection that already exists is never seeded again")
    }

    /// On w1, Cmd+click w3 and w2, then drag: every filled row moves together,
    /// whichever of them the drag starts on.
    func testDraggingFromTheSeededCurrentRowCarriesTheWholeBlockInRailOrder() {
        var selection = WorkspaceSelection()
        _ = selection.click(w3, commandHeld: true, current: w1, order: order)
        _ = selection.click(w2, commandHeld: true, current: w1, order: order)
        XCTAssertEqual(selection.dragSubject(pressing: w1, order: order), .workspaces([w1, w2, w3]))
        XCTAssertEqual(selection.dragSubject(pressing: w3, order: order), .workspaces([w1, w2, w3]))
    }

    // MARK: - the fill

    func testTheFillMarksTheCurrentRowOnlyWhileNothingIsSelected() {
        let none = WorkspaceSelection()
        XCTAssertTrue(none.showsFill(w1, isCurrent: true))
        XCTAssertFalse(none.showsFill(w2, isCurrent: false))

        let some = WorkspaceSelection(ids: [w2, w3])
        XCTAssertFalse(some.showsFill(w1, isCurrent: true), "a current row toggled out of the selection must not look selected")
        XCTAssertTrue(some.showsFill(w2, isCurrent: false))
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

    func testAFinishedDragEndsTheSelection() {
        var selection = twoSelectedByCommandClick()
        selection.dragFinished()
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
