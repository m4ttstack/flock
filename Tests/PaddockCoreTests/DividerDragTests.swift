import XCTest
import CoreGraphics
@testable import PaddockCore

/// Builds a `DividerHandle` the way `CanvasGeometry.dividerFrame` would for
/// a given region/direction/ratio, so every fixture here is realistic --
/// `frame` really does straddle `regionFrame`'s boundary at `ratio`, exactly
/// as the real geometry pass produces. `cellExtent` defaults far above any
/// floor so it does not interfere with tests that are not about the floor
/// clamp itself.
private func makeDivider(
    tabID: TabID = TabID(rawValue: "w:t"),
    path: [Bool] = [],
    region: CGRect,
    direction: SplitDirection,
    ratio: Double,
    thickness: CGFloat = 6,
    cellExtent: Int = 1000
) -> DividerHandle {
    // `PaneBox` gives an odd gutter's extra point to the trailing side, which
    // is what puts the drawn gutter's midpoint half a point off the boundary
    // it straddles. Mirrored here rather than centred, or a fixture at the
    // real 9pt gutter would not reproduce the geometry it stands for.
    let before = PaneBox.trailingInset(dividerThickness: thickness)
    let frame: CGRect
    switch direction {
    case .right:
        let boundaryX = region.minX + CGFloat(ratio) * region.width
        frame = CGRect(x: boundaryX - before, y: region.minY, width: thickness, height: region.height)
    case .down:
        let boundaryY = region.minY + CGFloat(ratio) * region.height
        frame = CGRect(x: region.minX, y: boundaryY - before, width: region.width, height: thickness)
    }
    return DividerHandle(tabID: tabID, path: path, frame: frame, direction: direction, regionFrame: region, cellExtent: cellExtent)
}

private func point(forRatio ratio: Double, divider: DividerHandle) -> CGPoint {
    let boundary = DividerDragMath.boundary(forRatio: ratio, divider: divider)
    switch divider.direction {
    case .right: return CGPoint(x: boundary, y: divider.regionFrame.midY)
    case .down: return CGPoint(x: divider.regionFrame.midX, y: boundary)
    }
}

final class DividerDragMathTests: XCTestCase {
    private let tabID = TabID(rawValue: "w:t")

    func testRatioAtPointerForRightDividerIsPointerOverRegionWidth() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 180, y: 150), divider: divider)

        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
    }

    func testRatioAtPointerForDownDividerIsPointerOverRegionHeight() {
        let region = CGRect(x: 0, y: 0, width: 300, height: 600)
        let divider = makeDivider(region: region, direction: .down, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 150, y: 420), divider: divider)

        XCTAssertEqual(ratio, 0.7, accuracy: 0.001)
    }

    func testRatioClampsToMinimum() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 10, y: 150), divider: divider)

        XCTAssertEqual(ratio, 0.1, accuracy: 0.0001)
    }

    func testRatioClampsToMaximum() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 590, y: 150), divider: divider)

        XCTAssertEqual(ratio, 0.9, accuracy: 0.0001)
    }

    /// 20 cells wide, `.right` floor is 4 -> the tightest legal fraction is
    /// 4/20 = 0.2, tighter than the plain 0.1 floor. A pointer far enough
    /// left to ask for 0.05 must land at 0.2, not 0.1.
    func testCellFloorClampIsTighterThanThePlainRatioClampForARightSplit() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5, cellExtent: 20)

        let low = DividerDragMath.ratio(atPointer: CGPoint(x: 30, y: 150), divider: divider)
        let high = DividerDragMath.ratio(atPointer: CGPoint(x: 570, y: 150), divider: divider)

        XCTAssertEqual(low, 0.2, accuracy: 0.0001)
        XCTAssertEqual(high, 0.8, accuracy: 0.0001)
    }

    /// Same shape, `.down` direction: the floor is 2 rows, not 4 columns, so
    /// a 10-row region's tightest fraction is 2/10 = 0.2 -- proving the
    /// clamp reads the direction-specific floor, not a fixed constant.
    func testCellFloorClampUsesTheSmallerRowFloorForADownSplit() {
        let region = CGRect(x: 0, y: 0, width: 300, height: 600)
        let divider = makeDivider(region: region, direction: .down, ratio: 0.5, cellExtent: 10)

        let low = DividerDragMath.ratio(atPointer: CGPoint(x: 150, y: 30), divider: divider)

        XCTAssertEqual(low, 0.2, accuracy: 0.0001)
    }

    /// `rawRatio` is what `began` samples a divider's CURRENT position with:
    /// it must read the true, unclamped ratio even when that ratio sits
    /// below what the cell floor would allow a COMMIT to land on -- a
    /// divider can already be there from before this clamp existed, and
    /// nothing has moved yet to justify snapping it.
    func testRawRatioIsNotClampedByTheCellFloorOrThePlainRange() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        // ratio 0.03: below both the plain 0.1 floor and, at cellExtent 20,
        // the 0.2 cell-floor fraction `ratio(atPointer:)` would enforce.
        let divider = makeDivider(region: region, direction: .right, ratio: 0.03, cellExtent: 20)

        let raw = DividerDragMath.rawRatio(atPointer: CGPoint(x: divider.frame.midX, y: divider.frame.midY), divider: divider)
        let clamped = DividerDragMath.ratio(atPointer: CGPoint(x: divider.frame.midX, y: divider.frame.midY), divider: divider)

        XCTAssertEqual(raw, 0.03, accuracy: 0.001)
        XCTAssertEqual(clamped, 0.2, accuracy: 0.001, "the clamped sibling still snaps -- proving the two genuinely differ, not that clamping was skipped everywhere")
    }

    /// 6 cells wide can never seat two 4-cell-floor children at once (would
    /// need 8): the floor-aware range is empty, so the clamp falls back to
    /// the plain ratio clamp rather than producing a lower bound above the
    /// upper bound.
    func testCellFloorClampFallsBackToThePlainRatioClampWhenNoValidRangeExists() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5, cellExtent: 6)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 30, y: 150), divider: divider)

        XCTAssertEqual(ratio, 0.1, accuracy: 0.0001)
    }

    func testRatioAtPointerWithZeroWidthRegionReturnsMidpointRatherThanDividingByZero() {
        let region = CGRect(x: 100, y: 0, width: 0, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 100, y: 150), divider: divider)

        XCTAssertEqual(ratio, 0.5)
    }

    func testRatioAtPointerWithZeroHeightRegionReturnsMidpointRatherThanDividingByZero() {
        let region = CGRect(x: 0, y: 50, width: 300, height: 0)
        let divider = makeDivider(region: region, direction: .down, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 150, y: 50), divider: divider)

        XCTAssertEqual(ratio, 0.5)
    }

    /// `regionFrame` is what `ratio(atPointer:)` must read, never `frame`
    /// (the thin gutter) or some externally-passed canvas rect: a divider
    /// nested two levels down, whose `regionFrame` sits well inside a much
    /// larger canvas, still resolves correctly against ITS OWN region.
    func testRatioReadsRegionFrameNotSomeOuterCanvasExtent() {
        let nestedRegion = CGRect(x: 400, y: 0, width: 100, height: 300)
        let divider = makeDivider(path: [true, false], region: nestedRegion, direction: .right, ratio: 0.5)

        let ratio = DividerDragMath.ratio(atPointer: CGPoint(x: 425, y: 150), divider: divider)

        XCTAssertEqual(ratio, 0.25, accuracy: 0.001)
    }

    func testBoundaryForRatioIsTheInverseOfRatioAtPointerForARightDivider() {
        let region = CGRect(x: 0, y: 0, width: 600, height: 300)
        let divider = makeDivider(region: region, direction: .right, ratio: 0.5)

        let boundary = DividerDragMath.boundary(forRatio: 0.3, divider: divider)

        XCTAssertEqual(boundary, 180, accuracy: 0.001)
    }

    func testBoundaryForRatioIsTheInverseOfRatioAtPointerForADownDivider() {
        let region = CGRect(x: 0, y: 0, width: 300, height: 600)
        let divider = makeDivider(region: region, direction: .down, ratio: 0.5)

        let boundary = DividerDragMath.boundary(forRatio: 0.7, divider: divider)

        XCTAssertEqual(boundary, 420, accuracy: 0.001)
    }

    /// A nested region offset from the origin on both axes: `boundary`
    /// must incorporate `regionFrame.minX`/`minY`, not just scale by width,
    /// or a nested divider's live line would paint at the wrong absolute
    /// position.
    func testBoundaryForRatioOnANestedRegionIncludesTheRegionsOwnOrigin() {
        let nestedRegion = CGRect(x: 400, y: 100, width: 100, height: 50)
        let divider = makeDivider(path: [true], region: nestedRegion, direction: .down, ratio: 0.5)

        let boundary = DividerDragMath.boundary(forRatio: 0.4, divider: divider)

        XCTAssertEqual(boundary, 120, accuracy: 0.001)
    }
}

final class DividerDragMachineTests: XCTestCase {
    private let tabID = TabID(rawValue: "w:t")
    private let region = CGRect(x: 0, y: 0, width: 600, height: 300)

    private func divider(path: [Bool] = [true], ratio: Double = 0.5, cellExtent: Int = 1000) -> DividerHandle {
        makeDivider(tabID: tabID, path: path, region: region, direction: .right, ratio: ratio, cellExtent: cellExtent)
    }

    func testBeganDerivesStartRatioFromTheDividersOwnPositionNotAPressLocation() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.62)

        XCTAssertTrue(machine.began(d))

        guard case .dragging(_, let startRatio, let liveRatio) = machine.phase else {
            return XCTFail("expected a dragging phase after began")
        }
        XCTAssertEqual(startRatio, 0.62, accuracy: 0.001)
        XCTAssertEqual(liveRatio, 0.62, accuracy: 0.001)
    }

    /// The real gutter is 9pt, which `PaneBox` splits 4 leading and 5
    /// trailing, so the drawn gutter's own midpoint is half a point off the
    /// edge the two boxes share. A press samples the edge.
    func testTheBoundaryPointIsTheSharedEdgeNotTheDrawnGuttersMidpoint() {
        let vertical = makeDivider(region: region, direction: .right, ratio: 0.5, thickness: 9)
        XCTAssertEqual(vertical.frame.midX, 299.5, accuracy: 0.0001, "the drawn gutter is off-centre by construction")
        XCTAssertEqual(vertical.boundaryPoint.x, 300, accuracy: 0.0001)

        let horizontal = makeDivider(region: region, direction: .down, ratio: 0.5, thickness: 9)
        XCTAssertEqual(horizontal.frame.midY, 149.5, accuracy: 0.0001)
        XCTAssertEqual(horizontal.boundaryPoint.y, 150, accuracy: 0.0001)
    }

    /// The live preview places a ratio to the pixel, so a start ratio taken
    /// from the drawn gutter's midpoint would move both boxes on a press that
    /// moved nothing.
    func testABarePressStartsAtTheDividersOwnBoundaryThroughAnOddGutter() {
        var machine = DividerDragMachine()
        let d = makeDivider(region: region, direction: .right, ratio: 0.5, thickness: 9)

        XCTAssertTrue(machine.began(d))

        guard case .dragging(_, let startRatio, _) = machine.phase else {
            return XCTFail("expected a dragging phase after began")
        }
        XCTAssertEqual(startRatio, 0.5, accuracy: 0.000001)
    }

    /// A divider already sitting below the cell floor (reachable from
    /// before this clamp existed) must not jump the moment it is pressed:
    /// `began` samples its true current position, not the floor-clamped one
    /// `moved`/`ended` would enforce on an actual commit.
    func testBeganDoesNotSnapAStartRatioAlreadyBelowTheCellFloor() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.03, cellExtent: 20)

        XCTAssertTrue(machine.began(d))

        guard case .dragging(_, let startRatio, let liveRatio) = machine.phase else {
            return XCTFail("expected a dragging phase after began")
        }
        XCTAssertEqual(startRatio, 0.03, accuracy: 0.001)
        XCTAssertEqual(liveRatio, 0.03, accuracy: 0.001)
    }

    func testReleaseIssuesExactlyOneOpWithTheDividersOwnPath() {
        var machine = DividerDragMachine()
        let d = divider(path: [true], ratio: 0.5)

        _ = machine.began(d)
        machine.moved(to: point(forRatio: 0.62, divider: d))
        let op = machine.ended()

        guard case let .setSplitRatio(opTab, opPath, opRatio)? = op else {
            return XCTFail("expected a setSplitRatio op")
        }
        XCTAssertEqual(opTab, tabID)
        XCTAssertEqual(opPath, [true])
        XCTAssertEqual(opRatio, 0.62, accuracy: 0.001)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testReleaseWithNoActualRatioChangeIssuesNoOp() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.5)

        _ = machine.began(d)
        machine.moved(to: point(forRatio: 0.5, divider: d))
        let op = machine.ended()

        XCTAssertNil(op)
    }

    func testIntermediateMovesUpdateLiveRatioButOnlyEndedProducesAnOp() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.4)

        _ = machine.began(d)
        machine.moved(to: point(forRatio: 0.45, divider: d))
        machine.moved(to: point(forRatio: 0.5, divider: d))
        machine.moved(to: point(forRatio: 0.55, divider: d))

        guard case let .dragging(_, startRatio, liveRatio) = machine.phase else {
            return XCTFail("expected a live dragging phase after moves")
        }
        XCTAssertEqual(startRatio, 0.4, accuracy: 0.001)
        XCTAssertEqual(liveRatio, 0.55, accuracy: 0.001)

        guard case let .setSplitRatio(_, _, opRatio)? = machine.ended() else {
            return XCTFail("expected ended() to issue the final ratio")
        }
        XCTAssertEqual(opRatio, 0.55, accuracy: 0.001)
    }

    func testEndedWithNoActiveDragReturnsNil() {
        var machine = DividerDragMachine()
        XCTAssertNil(machine.ended())
    }

    func testCancelledWithNoActiveDragReturnsNil() {
        var machine = DividerDragMachine()
        XCTAssertNil(machine.cancelled())
    }

    func testCancelledTransitionsToAwaitingReleaseAndReturnsTheStartRatio() throws {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.5)

        _ = machine.began(d)
        machine.moved(to: point(forRatio: 0.7, divider: d))
        let restored = try XCTUnwrap(machine.cancelled())

        XCTAssertEqual(restored, 0.5, accuracy: 0.001)
        XCTAssertEqual(machine.phase, .cancelledAwaitingRelease)
    }

    /// Press, drag, Esc (the phase correctly leaves `.dragging`), then keep
    /// moving the mouse without releasing, then release. Composing
    /// `DragGestureMachine`'s own latch is what makes the re-arm attempt
    /// during `.cancelledAwaitingRelease` a no-op; this fails under an
    /// implementation that re-arms on the next `began`.
    func testEscLatchesAgainstARearmUntilTheRelease() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.5)

        XCTAssertTrue(machine.began(d))
        machine.moved(to: point(forRatio: 0.6, divider: d))
        _ = machine.cancelled()

        let rearmed = machine.began(d)
        machine.moved(to: point(forRatio: 0.9, divider: d))

        XCTAssertFalse(rearmed, "a begin during cancelledAwaitingRelease must not re-arm the drag")
        XCTAssertNil(machine.ended(), "no op may be issued after Esc even if the pointer kept moving before release")
        XCTAssertEqual(machine.phase, .idle)
    }

    /// After the release that finally lands, a brand new press must work
    /// normally again -- the latch is scoped to one gesture, not permanent.
    func testAFreshBeginAfterTheReleaseFollowingEscStartsCleanly() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.5)

        _ = machine.began(d)
        _ = machine.cancelled()
        _ = machine.ended()

        XCTAssertTrue(machine.began(d))
        machine.moved(to: point(forRatio: 0.65, divider: d))
        guard case let .setSplitRatio(_, _, opRatio)? = machine.ended() else {
            return XCTFail("expected the fresh gesture to issue its own op")
        }
        XCTAssertEqual(opRatio, 0.65, accuracy: 0.001)
    }

    /// The app resigning active mid-drag must end the gesture with no op,
    /// and must not leave the machine unable to start a fresh drag
    /// afterward (unlike Esc, there is no "awaiting release" to wait
    /// through -- there is nothing left to release).
    func testAbandonedIssuesNoOpAndAllowsAFreshBeginAfterward() {
        var machine = DividerDragMachine()
        let d = divider(ratio: 0.5)

        _ = machine.began(d)
        machine.moved(to: point(forRatio: 0.7, divider: d))
        machine.abandoned()

        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.ended())
        XCTAssertTrue(machine.began(d), "a fresh press after an abandon must be able to start a new drag")
    }
}
