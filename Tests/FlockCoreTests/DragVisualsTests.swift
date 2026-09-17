import XCTest
import CoreGraphics
@testable import FlockCore

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

    // MARK: - a proxy that hangs from its strip

    private let thumbnail = CGRect(x: 200, y: 120, width: 103, height: 101)
    private let stripHeight: CGFloat = 15

    /// The pointer keeps the place in the strip it grabbed, so the proxy
    /// covers the thumbnail it came from on the press and travels exactly as
    /// far as the pointer does from there.
    func testATabProxyHangsFromTheStripWhereverInItTheGrabLanded() {
        for x in [2.0, 51.5, 101.0] as [CGFloat] {
            let inItem = CGPoint(x: x, y: 9)
            let anchor = DragVisuals.stripAnchor(grabbedAt: inItem, in: thumbnail.size, stripHeight: stripHeight)
            XCTAssertEqual(anchor, inItem, "\(x)")
            XCTAssertLessThanOrEqual(anchor.y, stripHeight, "the pointer left the strip at \(x)")

            let grab = CGPoint(x: thumbnail.minX + inItem.x, y: thumbnail.minY + inItem.y)
            let top = DragVisuals.ghostTopLeft(forCursor: grab, ghostSize: thumbnail.size, anchor: anchor)
            XCTAssertEqual(top, thumbnail.origin, "the proxy jumped off its own thumbnail at \(x)")
            let moved = DragVisuals.ghostTopLeft(
                forCursor: CGPoint(x: grab.x + 7, y: grab.y - 3), ghostSize: thumbnail.size, anchor: anchor
            )
            XCTAssertEqual(moved, CGPoint(x: top.x + 7, y: top.y - 3), "the first move moved the proxy by more than the pointer at \(x)")
        }
    }

    /// A tab is 101pt tall and its strip 15: a grab on the body hangs the
    /// proxy from the strip's lower edge rather than leaving the pointer over
    /// the mini panes.
    func testAGrabBelowTheStripIsPulledUpIntoItOnATallTab() {
        let anchor = DragVisuals.stripAnchor(grabbedAt: CGPoint(x: 60, y: 88), in: thumbnail.size, stripHeight: stripHeight)
        XCTAssertEqual(anchor, CGPoint(x: 60, y: stripHeight))
        XCTAssertLessThanOrEqual(anchor.y, stripHeight)
        let grab = CGPoint(x: thumbnail.minX + 60, y: thumbnail.minY + 88)
        let top = DragVisuals.ghostTopLeft(forCursor: grab, ghostSize: thumbnail.size, anchor: anchor)
        XCTAssertEqual(top.y, grab.y - stripHeight, "the strip is under the pointer")
        XCTAssertEqual(
            DragVisuals.ghostTopLeft(forCursor: CGPoint(x: grab.x + 4, y: grab.y + 4), ghostSize: thumbnail.size, anchor: anchor),
            CGPoint(x: top.x + 4, y: top.y + 4)
        )
    }

    /// A tab whose thumbnail never reported a frame is proxied at the
    /// ordinary bounds instead of its own size, so the grab can fall outside
    /// the proxy entirely.
    func testAGrabOutsideASmallerProxyIsPulledInsideIt() {
        let anchor = DragVisuals.stripAnchor(
            grabbedAt: CGPoint(x: 99, y: 12), in: CGSize(width: 44, height: 22), stripHeight: stripHeight
        )
        XCTAssertEqual(anchor, CGPoint(x: 44, y: 12))
    }

    /// The landing and the spring back hold the proxy the way the drag did:
    /// the point the pointer held goes to the same place in the region, which
    /// puts a tab's own strip over the strip of the slot it landed in.
    func testAnAnchoredProxySettlesTheWayItHung() {
        let anchor = CGPoint(x: 51.5, y: 9)
        let slot = CGRect(x: 400, y: 260, width: 103, height: 101)
        XCTAssertEqual(DragVisuals.settleTopLeft(on: slot, grabPoint: .zero, ghostSize: slot.size, anchor: anchor), slot.origin)

        let shorter = CGRect(x: 400, y: 260, width: 60, height: 40)
        XCTAssertEqual(
            DragVisuals.settleTopLeft(on: shorter, grabPoint: .zero, ghostSize: slot.size, anchor: anchor), shorter.origin,
            "a region of another size still takes the proxy by its strip"
        )
        XCTAssertEqual(
            DragVisuals.settleTopLeft(on: nil, grabPoint: CGPoint(x: 10, y: 20), ghostSize: slot.size, anchor: anchor),
            CGPoint(x: 10 - anchor.x, y: 20 - anchor.y)
        )
        XCTAssertNotEqual(
            DragVisuals.settleTopLeft(on: shorter, grabPoint: .zero, ghostSize: slot.size, anchor: anchor),
            DragVisuals.settleTopLeft(on: shorter, grabPoint: .zero, ghostSize: slot.size),
            "a centred settle and an anchored one agree only where the two sizes match"
        )
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

    // MARK: - wrapped slots

    /// Eight card slots, four to a row: 90 wide on a 100pt pitch, 101 tall on
    /// a 111pt one.
    private let cardSlots = (0..<8).map {
        CGRect(x: 10 + CGFloat($0 % 4) * 100, y: 50 + CGFloat($0 / 4) * 111, width: 90, height: 101)
    }

    /// One rule, two shapes of list: over slots that do not wrap, the vector
    /// form is the strip's own extent form, for every item and every gap.
    func testASlotOffsetIsTheStripsOwnRuleWhereTheSlotsDoNotWrap() {
        let row = Array(cardSlots.prefix(4))
        let subjects: [Int?] = [nil] + row.indices.map { $0 }
        for dragging in subjects {
            for insertIndex in 0...row.count {
                for index in row.indices {
                    let offset = ReshuffleOffset.slotOffset(
                        forItemAt: index, draggingIndex: dragging, insertIndex: insertIndex, slots: row
                    )
                    let expected = ReshuffleOffset.displacement(
                        forItemAt: index, draggingIndex: dragging, insertIndex: insertIndex, extent: 100
                    )
                    // The arriving-item case has no slot past the last one to
                    // move the tail into, which is what a card previews with a
                    // placeholder instead.
                    guard dragging != nil || index + 1 < row.count || insertIndex > index else {
                        XCTAssertEqual(offset, .zero, "item \(index), gap \(insertIndex)")
                        continue
                    }
                    XCTAssertEqual(offset.width, expected, "item \(index), dragging \(String(describing: dragging)), gap \(insertIndex)")
                    XCTAssertEqual(offset.height, 0)
                }
            }
        }
    }

    /// A tab dragged past the end of its row lands on the next row, so its
    /// own slide is up or down as well as along, and the tab it displaces
    /// comes back the other way.
    func testATabCrossingARowEndMovesDownAsWellAsAlong() {
        let toNextRow = ReshuffleOffset.slotOffset(forItemAt: 0, draggingIndex: 0, insertIndex: 5, slots: cardSlots)
        XCTAssertEqual(toNextRow, CGSize(width: 0, height: 111), "slot 0 to slot 4, the first of the next row")

        let displaced = ReshuffleOffset.slotOffset(forItemAt: 4, draggingIndex: 0, insertIndex: 5, slots: cardSlots)
        XCTAssertEqual(displaced, CGSize(width: 300, height: -111), "slot 4 back to slot 3, the last of the first row")

        let untouched = ReshuffleOffset.slotOffset(forItemAt: 5, draggingIndex: 0, insertIndex: 5, slots: cardSlots)
        XCTAssertEqual(untouched, .zero)
    }

    /// Exactly one cell per slot, at every gap: the previewed positions are
    /// the resting positions, reordered, so a card mid-reorder never draws
    /// two thumbnails on top of each other or leaves a hole.
    func testAPreviewedCardFillsEverySlotExactlyOnce() {
        let resting = cardSlots.map { CGPoint(x: $0.minX, y: $0.minY) }
        for dragging in cardSlots.indices {
            for insertIndex in 0...cardSlots.count {
                let landed = cardSlots.indices.map { index -> CGPoint in
                    let offset = ReshuffleOffset.slotOffset(
                        forItemAt: index, draggingIndex: dragging, insertIndex: insertIndex, slots: cardSlots
                    )
                    return CGPoint(x: cardSlots[index].minX + offset.width, y: cardSlots[index].minY + offset.height)
                }
                XCTAssertEqual(
                    landed.sorted { ($0.y, $0.x) < ($1.y, $1.x) }, resting,
                    "dragging \(dragging) at gap \(insertIndex)"
                )
            }
        }
    }

    /// A card draws only the slots it has: an index the arrangement does not
    /// carry moves nothing rather than reading past the end.
    func testASlotTheCardDoesNotDrawMovesNothing() {
        XCTAssertEqual(ReshuffleOffset.slotOffset(forItemAt: 9, draggingIndex: 0, insertIndex: 2, slots: cardSlots), .zero)
        XCTAssertEqual(ReshuffleOffset.slotOffset(forItemAt: 0, draggingIndex: nil, insertIndex: 0, slots: []), .zero)
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
