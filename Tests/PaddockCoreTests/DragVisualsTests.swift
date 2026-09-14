import XCTest
import CoreGraphics
@testable import PaddockCore

final class DragVisualsTests: XCTestCase {
    func testGhostSitsBelowAndRightOfTheCursor() {
        let top = DragVisuals.ghostTopLeft(forCursor: CGPoint(x: 100, y: 40))
        XCTAssertEqual(top, CGPoint(x: 116, y: 48))
    }

    func testGhostSizeShrinksAPaneToFitTheCapAndKeepsItsAspect() {
        let size = DragVisuals.ghostSize(forOrigin: CGSize(width: 800, height: 400))
        XCTAssertEqual(size.width, 260, accuracy: 0.001)
        XCTAssertEqual(size.height, 130, accuracy: 0.001)
    }

    func testGhostSizeLeavesSomethingAlreadySmallerAlone() {
        let size = DragVisuals.ghostSize(forOrigin: CGSize(width: 90, height: 30))
        XCTAssertEqual(size, CGSize(width: 90, height: 30))
    }

    func testGhostSizeFallsBackToTheCapForADegenerateOrigin() {
        XCTAssertEqual(DragVisuals.ghostSize(forOrigin: .zero), CGSize(width: 260, height: 160))
    }

    func testThresholdRejectsAPressThatBarelyMoves() {
        XCTAssertFalse(DragThreshold.passed(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 12)))
    }

    func testThresholdPassesOnceFourPointsAreTravelled() {
        XCTAssertTrue(DragThreshold.passed(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 10)))
        XCTAssertTrue(DragThreshold.passed(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 6)))
    }

    func testGrabRegionTakesTheTopBandAtRest() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertTrue(PaneGrabRegion.armsDrag(at: CGPoint(x: 200, y: 4), in: bounds, rearrangeActive: false))
        XCTAssertTrue(PaneGrabRegion.armsDrag(at: CGPoint(x: 200, y: 12), in: bounds, rearrangeActive: false))
    }

    func testGrabRegionLeavesTheBodyToTheTerminalAtRest() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertFalse(PaneGrabRegion.armsDrag(at: CGPoint(x: 200, y: 13), in: bounds, rearrangeActive: false))
        XCTAssertFalse(PaneGrabRegion.armsDrag(at: CGPoint(x: 200, y: 290), in: bounds, rearrangeActive: false))
    }

    func testGrabRegionTakesTheWholePaneWhileRearranging() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertTrue(PaneGrabRegion.armsDrag(at: CGPoint(x: 200, y: 290), in: bounds, rearrangeActive: true))
    }

    func testGrabRegionIgnoresAPointOutsideTheBody() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertFalse(PaneGrabRegion.armsDrag(at: CGPoint(x: 410, y: 2), in: bounds, rearrangeActive: true))
    }

    /// Three items, the first dragged into the last gap: only the two it
    /// passes actually move, and it moves none of itself.
    func testReshuffleMovesOnlyTheItemsBetweenOldAndNewPosition() {
        let extent: CGFloat = 60
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: 0, insertIndex: 2, extent: extent), 0)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: 0, insertIndex: 2, extent: extent), -60)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: 0, insertIndex: 2, extent: extent), 0)
    }

    func testReshuffleMovesNothingWhenTheInsertIndexIsTheItemsOwnPlace() {
        let extent: CGFloat = 60
        for index in 0..<3 {
            XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: index, draggingIndex: 0, insertIndex: 0, extent: extent), 0)
        }
    }

    func testReshuffleMovesTheTailForwardWhenTheDraggedItemComesFromAnotherList() {
        let extent: CGFloat = 60
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: nil, insertIndex: 1, extent: extent), 0)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: nil, insertIndex: 1, extent: extent), 60)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: nil, insertIndex: 1, extent: extent), 60)
    }
}
