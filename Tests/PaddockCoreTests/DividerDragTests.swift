import XCTest
import CoreGraphics
@testable import PaddockCore

final class DividerDragMathTests: XCTestCase {
    private let tabID = TabID(rawValue: "w:t")

    func testRatioAtPointerForRightDividerIsPointerOverCanvasWidth() {
        let canvas = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 297, y: 0, width: 6, height: 300), direction: .right)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 180, y: 150), divider: divider, dividers: [divider], canvas: canvas)

        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
    }

    func testRatioAtPointerForDownDividerIsPointerOverCanvasHeight() {
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 600)
        let divider = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 0, y: 297, width: 300, height: 6), direction: .down)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 150, y: 420), divider: divider, dividers: [divider], canvas: canvas)

        XCTAssertEqual(ratio, 0.7, accuracy: 0.001)
    }

    func testRatioClampsToMinimum() {
        let canvas = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 297, y: 0, width: 6, height: 300), direction: .right)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 10, y: 150), divider: divider, dividers: [divider], canvas: canvas)

        XCTAssertEqual(ratio, 0.1, accuracy: 0.0001)
    }

    func testRatioClampsToMaximum() {
        let canvas = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 297, y: 0, width: 6, height: 300), direction: .right)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 590, y: 150), divider: divider, dividers: [divider], canvas: canvas)

        XCTAssertEqual(ratio, 0.9, accuracy: 0.0001)
    }

    /// A `.right` split nested inside the second child of another `.right`
    /// split: the nested divider's own along-axis extent is the parent's
    /// second-child region (canvas x 100...200), never the whole 200pt
    /// canvas -- a pointer at x:150 must read as the midpoint of THAT
    /// region (ratio 0.5), not 150/200 (0.75) against the full canvas.
    func testNestedSplitExtentIsTheParentsChildRegionNotTheWholeCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let root = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 97, y: 0, width: 6, height: 100), direction: .right)
        let nested = DividerHandle(tabID: tabID, path: [true], frame: CGRect(x: 147, y: 0, width: 6, height: 100), direction: .right)
        let dividers = [root, nested]

        let region = DividerDragMath.region(for: nested.path, tabID: tabID, dividers: dividers, canvas: canvas)
        XCTAssertEqual(region, CGRect(x: 100, y: 0, width: 100, height: 100))

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 150, y: 50), divider: nested, dividers: dividers, canvas: canvas)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    }

    /// A `.down` split nested in a `.right` split's second child: the nested
    /// extent still spans the full canvas height (the ancestor only divides
    /// x), proving `region(for:)` does not blindly shrink on every level.
    func testNestedDownSplitInheritsFullCrossAxisFromAnUnrelatedAncestorDirection() {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let root = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 97, y: 0, width: 6, height: 100), direction: .right)
        let nested = DividerHandle(tabID: tabID, path: [true], frame: CGRect(x: 100, y: 37, width: 100, height: 6), direction: .down)
        let dividers = [root, nested]

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 150, y: 40), divider: nested, dividers: dividers, canvas: canvas)

        XCTAssertEqual(ratio, 0.4, accuracy: 0.001)
    }

    func testBoundaryForRatioIsTheInverseOfRatioAtPointer() {
        let canvas = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = DividerHandle(tabID: tabID, path: [], frame: CGRect(x: 297, y: 0, width: 6, height: 300), direction: .right)

        let boundary = DividerDragMath.boundary(forRatio: 0.3, divider: divider, dividers: [divider], canvas: canvas)

        XCTAssertEqual(boundary, 180, accuracy: 0.001)
    }
}

final class DividerDragMachineTests: XCTestCase {
    private let tabID = TabID(rawValue: "w:t")

    private func divider(path: [Bool] = [true]) -> DividerHandle {
        DividerHandle(tabID: tabID, path: path, frame: CGRect(x: 297, y: 0, width: 6, height: 300), direction: .right)
    }

    func testReleaseIssuesExactlyOneOpWithTheDividersOwnPath() {
        var machine = DividerDragMachine()
        let d = divider(path: [true])

        machine.began(d, startRatio: 0.5)
        machine.moved(to: 0.62)
        let op = machine.ended()

        XCTAssertEqual(op, .setSplitRatio(tab: tabID, path: [true], ratio: 0.62))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testEscIssuesNoOpAndRestoresTheStartRatio() {
        var machine = DividerDragMachine()
        let d = divider()

        machine.began(d, startRatio: 0.5)
        machine.moved(to: 0.7)
        let restored = machine.cancelled()

        XCTAssertEqual(restored, 0.5)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.ended(), "a cancelled drag must never still produce an op from a later ended()")
    }

    func testReleaseWithNoActualRatioChangeIssuesNoOp() {
        var machine = DividerDragMachine()
        let d = divider()

        machine.began(d, startRatio: 0.5)
        machine.moved(to: 0.5)
        let op = machine.ended()

        XCTAssertNil(op)
    }

    func testMultipleMovesDuringOneDragProduceNoOpsThemselvesOnlyEndedDoes() {
        var machine = DividerDragMachine()
        let d = divider()

        machine.began(d, startRatio: 0.4)
        machine.moved(to: 0.45)
        machine.moved(to: 0.5)
        machine.moved(to: 0.55)
        guard case let .dragging(_, startRatio, liveRatio) = machine.phase else {
            return XCTFail("expected a live dragging phase after moves")
        }
        XCTAssertEqual(startRatio, 0.4)
        XCTAssertEqual(liveRatio, 0.55)

        let op = machine.ended()
        XCTAssertEqual(op, .setSplitRatio(tab: tabID, path: [true], ratio: 0.55))
    }

    func testEndedWithNoActiveDragReturnsNil() {
        var machine = DividerDragMachine()
        XCTAssertNil(machine.ended())
    }

    func testCancelledWithNoActiveDragReturnsNil() {
        var machine = DividerDragMachine()
        XCTAssertNil(machine.cancelled())
    }
}
