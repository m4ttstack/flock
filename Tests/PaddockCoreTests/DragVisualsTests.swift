import XCTest
import CoreGraphics
@testable import PaddockCore

final class DragVisualsTests: XCTestCase {
    func testGhostIsCenteredOnTheCursor() {
        let size = CGSize(width: 260, height: 130)
        let top = DragVisuals.ghostTopLeft(forCursor: CGPoint(x: 100, y: 40), ghostSize: size)
        XCTAssertEqual(top, CGPoint(x: -30, y: -25))
        XCTAssertEqual(CGPoint(x: top.x + size.width / 2, y: top.y + size.height / 2), CGPoint(x: 100, y: 40))
    }

    func testGhostCenteringHandlesAnOddSizeWithoutDrift() {
        let size = CGSize(width: 91, height: 31)
        let top = DragVisuals.ghostTopLeft(forCursor: CGPoint(x: 10, y: 10), ghostSize: size)
        XCTAssertEqual(top.x, 10 - 45.5, accuracy: 0.0001)
        XCTAssertEqual(top.y, 10 - 15.5, accuracy: 0.0001)
    }

    func testGhostSizeShrinksAPaneToFitTheCapAndKeepsItsAspect() {
        let size = DragVisuals.ghostSize(forOrigin: CGSize(width: 800, height: 400))
        XCTAssertEqual(size.width, 333, accuracy: 0.001)
        XCTAssertEqual(size.height, 166.5, accuracy: 0.001)
    }

    /// The floor is reached by scaling BOTH axes, never by stretching the
    /// short one: a tab pill is a wider, shorter proxy than a rail row, and a
    /// per-axis `max()` would hand them the same box.
    func testGhostSizeLiftsASmallOriginProportionallyRatherThanStretchingIt() {
        let pill = DragVisuals.ghostSize(forOrigin: CGSize(width: 100, height: 28))
        XCTAssertEqual(pill.width, 192, accuracy: 0.001, "the binding axis just meets the floor")
        XCTAssertEqual(pill.height, 53.76, accuracy: 0.001)

        let row = DragVisuals.ghostSize(forOrigin: CGSize(width: 172, height: 27))
        XCTAssertEqual(row.height, 41, accuracy: 0.001, "here the height binds instead")
        XCTAssertEqual(row.width, 261.185, accuracy: 0.001)
        XCTAssertNotEqual(pill, row)
    }

    /// The compact bounds are the same rule at grid scale: a mini pane and a
    /// thumbnail both already sit inside them, so each proxy is its own
    /// footprint exactly.
    func testAGridOriginIsItsOwnFootprintUnderTheCompactBounds() {
        let compact = DragVisuals.compactGhostBounds
        XCTAssertEqual(DragVisuals.ghostSize(forOrigin: CGSize(width: 45, height: 74), bounds: compact), CGSize(width: 45, height: 74))
        XCTAssertEqual(DragVisuals.ghostSize(forOrigin: CGSize(width: 74, height: 74), bounds: compact), CGSize(width: 74, height: 74))
        XCTAssertEqual(DragVisuals.ghostSize(forOrigin: CGSize(width: 103, height: 82), bounds: compact), CGSize(width: 103, height: 82))
    }

    /// A proxy drawn AS the thing it stands for is that thing's own size, at
    /// any shape: a tab miniature has to line up one to one with the
    /// thumbnail it left, which the compact cap would shrink (a 101pt-tall
    /// thumbnail against an 88pt cap).
    func testExactBoundsHoldAProxyAtItsOriginsOwnSize() {
        for origin in [CGSize(width: 103, height: 101), CGSize(width: 45, height: 74), CGSize(width: 800, height: 400)] {
            XCTAssertEqual(DragVisuals.ghostSize(forOrigin: origin, bounds: DragVisuals.exactBounds(origin)), origin)
        }
        XCTAssertNotEqual(
            DragVisuals.ghostSize(forOrigin: CGSize(width: 103, height: 101), bounds: DragVisuals.compactGhostBounds),
            CGSize(width: 103, height: 101),
            "the compact cap is what a miniature has to escape"
        )
    }

    /// Wide, tall, square and pill, under both bounds: one scale factor, so
    /// the proxy is always the origin's own shape and never outgrows the cap.
    func testEveryProxyKeepsItsOriginsAspectAndStaysInsideTheCap() {
        let origins = [
            CGSize(width: 800, height: 400), CGSize(width: 400, height: 900), CGSize(width: 74, height: 74),
            CGSize(width: 100, height: 28), CGSize(width: 45, height: 74), CGSize(width: 103, height: 82),
            CGSize(width: 1200, height: 60),
        ]
        for bounds in [DragVisuals.ghostBounds, DragVisuals.compactGhostBounds] {
            for origin in origins {
                let size = DragVisuals.ghostSize(forOrigin: origin, bounds: bounds)
                XCTAssertEqual(size.width / size.height, origin.width / origin.height, accuracy: 0.0001, "\(origin) \(size)")
                XCTAssertLessThanOrEqual(size.width, bounds.maximum.width + 0.0001, "\(origin) \(size)")
                XCTAssertLessThanOrEqual(size.height, bounds.maximum.height + 0.0001, "\(origin) \(size)")
            }
        }
    }

    /// A shape neither box can satisfy at once. The cap wins: a proxy that
    /// covers the drop target is worse than one that is small.
    func testAnOriginTooWideToMeetBothBoundsStaysInsideTheCap() {
        let size = DragVisuals.ghostSize(forOrigin: CGSize(width: 1200, height: 60))
        XCTAssertEqual(size.width, 333, accuracy: 0.001)
        XCTAssertEqual(size.height, 16.65, accuracy: 0.001)
        XCTAssertLessThan(size.height, DragVisuals.ghostBounds.minimum.height)
    }

    func testGhostSizeFallsBackToTheFloorForADegenerateOrigin() {
        XCTAssertEqual(DragVisuals.ghostSize(forOrigin: .zero), DragVisuals.ghostBounds.minimum)
    }

    /// A drop that commits nothing bounces the proxy onto the middle of the
    /// item it came from, wherever inside that item the press landed.
    func testAnUncommittedDropSettlesOntoTheItemItWasPickedUpFrom() {
        let home = CGRect(x: 100, y: 200, width: 60, height: 80)
        let ghost = CGSize(width: 60, height: 80)
        let top = DragVisuals.settleTopLeft(on: home, grabPoint: CGPoint(x: 105, y: 275), ghostSize: ghost)
        XCTAssertEqual(top, CGPoint(x: 100, y: 200))
    }

    /// A proxy is rarely its landing region's own size, so it centers on the
    /// region rather than matching origins with it: a 261x41 rail-row proxy
    /// would otherwise hang 89pt past the 172pt row it lands on.
    func testACommittedDropCentersTheProxyOnTheRegionItLandedIn() {
        let row = CGRect(x: 10, y: 100, width: 172, height: 27)
        let top = DragVisuals.settleTopLeft(on: row, grabPoint: .zero, ghostSize: CGSize(width: 261, height: 41))
        XCTAssertEqual(top, CGPoint(x: -34.5, y: 93), "overhanging both sides equally, not one")
        XCTAssertEqual(top.x + 261 / 2, row.midX)
        XCTAssertEqual(top.y + 41 / 2, row.midY)
    }

    /// Without a region the press point is the stand-in, which is what every
    /// drag outside the grid still uses.
    func testWithNoRegionTheSettleFallsBackToThePressPoint() {
        let ghost = CGSize(width: 60, height: 80)
        let top = DragVisuals.settleTopLeft(on: nil, grabPoint: CGPoint(x: 105, y: 275), ghostSize: ghost)
        XCTAssertEqual(top, CGPoint(x: 75, y: 235))
    }

    func testThresholdRejectsAPressThatBarelyMoves() {
        XCTAssertFalse(DragThreshold.passed(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 12)))
    }

    func testThresholdPassesOnceFourPointsAreTravelled() {
        XCTAssertTrue(DragThreshold.passed(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 10)))
        XCTAssertTrue(DragThreshold.passed(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 6)))
    }

    func testPaneContentStartsBelowThePaddingAndTitleRow() {
        XCTAssertEqual(PaneChrome.contentTop, 28)
        XCTAssertEqual(PaneChrome.size, CGSize(width: 26, height: 38))
    }

    func testPaneBodyIsTheTerminalsAtRest() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertFalse(PaneGrabRegion.bodyArmsDrag(at: CGPoint(x: 200, y: 1), in: bounds, rearrangeActive: false))
        XCTAssertFalse(PaneGrabRegion.bodyArmsDrag(at: CGPoint(x: 200, y: 290), in: bounds, rearrangeActive: false))
    }

    func testPaneBodyIsAllDragSurfaceWhileRearranging() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertTrue(PaneGrabRegion.bodyArmsDrag(at: CGPoint(x: 200, y: 290), in: bounds, rearrangeActive: true))
    }

    /// A body whose own space does not start at zero: the point still has to
    /// be inside it.
    func testPaneBodyIgnoresAPointOutsideItsBounds() {
        let bounds = CGRect(x: 40, y: 20, width: 400, height: 300)
        XCTAssertTrue(PaneGrabRegion.bodyArmsDrag(at: CGPoint(x: 60, y: 40), in: bounds, rearrangeActive: true))
        XCTAssertFalse(PaneGrabRegion.bodyArmsDrag(at: CGPoint(x: 20, y: 10), in: bounds, rearrangeActive: true))
        XCTAssertFalse(PaneGrabRegion.bodyArmsDrag(at: CGPoint(x: 460, y: 40), in: bounds, rearrangeActive: true))
    }

    /// Three items, the first dragged into the gap before the last: the
    /// preview is the whole arrangement, so the neighbour it passes slides
    /// back one slot and the origin takes the slot that neighbour vacated.
    /// Nothing is drawn twice in one place.
    func testForwardDragPreviewsTheWholeArrangement() {
        let extent: CGFloat = 110
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: 0, insertIndex: 2, extent: extent), 110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: 0, insertIndex: 2, extent: extent), -110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: 0, insertIndex: 2, extent: extent), 0)
    }

    func testForwardDragToTheEndMovesEveryItemItPasses() {
        let extent: CGFloat = 110
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: 0, insertIndex: 3, extent: extent), 220)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: 0, insertIndex: 3, extent: extent), -110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: 0, insertIndex: 3, extent: extent), -110)
    }

    /// The last item dragged to the front: the two it passes each slide
    /// forward one slot and it travels back over both.
    func testBackwardDragPreviewsTheWholeArrangement() {
        let extent: CGFloat = 110
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: 2, insertIndex: 0, extent: extent), 110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: 2, insertIndex: 0, extent: extent), 110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: 2, insertIndex: 0, extent: extent), -220)
    }

    func testBackwardDragOfOnePlaceSwapsTwoItems() {
        let extent: CGFloat = 110
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: 1, insertIndex: 0, extent: extent), 110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: 1, insertIndex: 0, extent: extent), -110)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: 1, insertIndex: 0, extent: extent), 0)
    }

    /// Both gaps either side of the dragged item name its own place.
    func testReshuffleMovesNothingWhenTheInsertIndexIsTheItemsOwnPlace() {
        let extent: CGFloat = 110
        for insertIndex in [1, 2] {
            for index in 0..<3 {
                XCTAssertEqual(
                    ReshuffleOffset.displacement(forItemAt: index, draggingIndex: 1, insertIndex: insertIndex, extent: extent),
                    0,
                    "index \(index) at insertIndex \(insertIndex)"
                )
            }
        }
    }

    func testAdvanceMeasuresTheItemPlusTheGapToItsNeighbor() {
        let pills = [
            CGRect(x: 12, y: 7, width: 100, height: 28),
            CGRect(x: 122, y: 7, width: 100, height: 28),
            CGRect(x: 232, y: 7, width: 100, height: 28)
        ]
        XCTAssertEqual(ReshuffleOffset.advance(ofItemAt: 0, items: pills, axis: .vertical), 110)
        XCTAssertEqual(ReshuffleOffset.advance(ofItemAt: 2, items: pills, axis: .vertical), 110)
    }

    func testAdvanceOfALoneItemIsItsOwnExtent() {
        let only = [CGRect(x: 8, y: 40, width: 200, height: 30)]
        XCTAssertEqual(ReshuffleOffset.advance(ofItemAt: 0, items: only, axis: .horizontal), 30)
    }

    func testAdvanceFallsBackForAnIndexThatIsNotThere() {
        XCTAssertEqual(ReshuffleOffset.advance(ofItemAt: 3, items: [], axis: .vertical), ReshuffleOffset.defaultExtent)
    }

    func testReshuffleMovesTheTailForwardWhenTheDraggedItemComesFromAnotherList() {
        let extent: CGFloat = 60
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 0, draggingIndex: nil, insertIndex: 1, extent: extent), 0)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 1, draggingIndex: nil, insertIndex: 1, extent: extent), 60)
        XCTAssertEqual(ReshuffleOffset.displacement(forItemAt: 2, draggingIndex: nil, insertIndex: 1, extent: extent), 60)
    }

    // MARK: - block reshuffle

    /// Rows 20 tall on a 22pt pitch.
    private let rows = (0..<5).map { CGRect(x: 0, y: CGFloat($0) * 22, width: 180, height: 20) }

    func testScatteredBlockDroppedAtTheEndPreviewsThePostDropOrder() {
        // Block {0, 2} to the end of four rows: [1, 3, 0, 2].
        let items = Array(rows.prefix(4))
        let block: Set<Int> = [0, 2]
        let offsets = (0..<4).map {
            ReshuffleOffset.blockDisplacement(forItemAt: $0, blockIndices: block, insertIndex: 4, items: items, axis: .horizontal)
        }
        XCTAssertEqual(offsets, [44, -22, 22, -44])
    }

    /// Exactly one item per slot, whatever the block and gap: the displaced
    /// positions are the resting positions, reordered.
    func testBlockPreviewNeverStacksTwoItemsInOneSlot() {
        let resting = rows.map(\.minY)
        for mask in 1..<(1 << rows.count) {
            let block = Set(rows.indices.filter { mask & (1 << $0) != 0 })
            for insertIndex in 0...rows.count {
                let landed = rows.indices.map {
                    rows[$0].minY + ReshuffleOffset.blockDisplacement(forItemAt: $0, blockIndices: block, insertIndex: insertIndex, items: rows, axis: .horizontal)
                }
                XCTAssertEqual(landed.sorted(), resting, "block \(block.sorted()) at gap \(insertIndex)")
            }
        }
    }

    func testBlockOfOneMatchesTheSingleReshuffle() {
        for dragging in rows.indices {
            for insertIndex in 0...rows.count {
                for index in rows.indices {
                    XCTAssertEqual(
                        ReshuffleOffset.blockDisplacement(forItemAt: index, blockIndices: [dragging], insertIndex: insertIndex, items: rows, axis: .horizontal),
                        ReshuffleOffset.displacement(forItemAt: index, draggingIndex: dragging, insertIndex: insertIndex, extent: 22),
                        "item \(index), dragging \(dragging), gap \(insertIndex)"
                    )
                }
            }
        }
    }
}
