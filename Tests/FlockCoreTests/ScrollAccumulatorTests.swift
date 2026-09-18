import XCTest
@testable import FlockCore

/// Every case up to the speed section drives `.normal`, which is what pins
/// today's cadence: the factor a flock nobody has configured applies.
final class ScrollAccumulatorTests: XCTestCase {
    private let cell = MouseForwarding.CellSize(width: 8, height: 16)

    /// A ~300pt precision swipe is floor(300/16) = 18 cell steps, not 30-60
    /// per-event reports, with the 12pt remainder carried.
    func testPreciseSwipeEmitsOneStepPerCellHeight() {
        var accumulator = ScrollAccumulator()
        var total = 0
        // Ten 30pt events, as a trackpad delivers them.
        for _ in 0..<10 {
            total += accumulator.add(deltaX: 0, deltaY: 30, precise: true, cellSize: cell, speed: .normal).y
        }
        XCTAssertEqual(total, 18)
        XCTAssertEqual(accumulator.pendingY, 12, accuracy: 0.0001)
    }

    func testPreciseRemainderCarriesAcrossEvents() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 10, precise: true, cellSize: cell, speed: .normal).y, 0)
        XCTAssertEqual(accumulator.pendingY, 10, accuracy: 0.0001)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 10, precise: true, cellSize: cell, speed: .normal).y, 1)
        XCTAssertEqual(accumulator.pendingY, 4, accuracy: 0.0001)
    }

    func testPreciseDirectionIsTheSignAndOppositeScrollUndoesPending() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -40, precise: true, cellSize: cell, speed: .normal).y, -2)
        XCTAssertEqual(accumulator.pendingY, -8, accuracy: 0.0001)
        // Scrolling back the other way first eats the pending remainder.
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 8, precise: true, cellSize: cell, speed: .normal).y, 0)
        XCTAssertEqual(accumulator.pendingY, 0, accuracy: 0.0001)
    }

    /// Non-precision wheel notches are whole cells; macOS reports slow single
    /// clicks as 0.1, which must still register as one step.
    func testDiscreteNotchIsOneStepAndSlowClickRoundsUpToOne() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 1, precise: false, cellSize: cell, speed: .normal).y, 1)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 0.1, precise: false, cellSize: cell, speed: .normal).y, 1)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.1, precise: false, cellSize: cell, speed: .normal).y, -1)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 3, precise: false, cellSize: cell, speed: .normal).y, 3)
        XCTAssertEqual(accumulator.pendingY, 0, accuracy: 0.0001)
    }

    func testHorizontalPreciseAccumulatesAgainstCellWidth() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 5, deltaY: 0, precise: true, cellSize: cell, speed: .normal).x, 0)
        XCTAssertEqual(accumulator.add(deltaX: 20, deltaY: 0, precise: true, cellSize: cell, speed: .normal).x, 3)
        XCTAssertEqual(accumulator.pendingX, 1, accuracy: 0.0001)
    }

    func testHorizontalDiscreteIsRoundedNotAccumulated() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 2.4, deltaY: 0, precise: false, cellSize: cell, speed: .normal).x, 2)
        XCTAssertEqual(accumulator.add(deltaX: -1.6, deltaY: 0, precise: false, cellSize: cell, speed: .normal).x, -2)
        XCTAssertEqual(accumulator.pendingX, 0, accuracy: 0.0001)
    }

    func testZeroDeltaEmitsNothing() {
        var accumulator = ScrollAccumulator()
        let steps = accumulator.add(deltaX: 0, deltaY: 0, precise: true, cellSize: cell, speed: .normal)
        XCTAssertEqual(steps.x, 0)
        XCTAssertEqual(steps.y, 0)
    }

    /// Discarded on a capture-off transition so a momentum tail cannot emit
    /// after the app stopped listening.
    func testResetDropsPending() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.add(deltaX: 3, deltaY: 10, precise: true, cellSize: cell, speed: .normal)
        accumulator.reset()
        XCTAssertEqual(accumulator.pendingX, 0)
        XCTAssertEqual(accumulator.pendingY, 0)
    }

    // MARK: - The chosen speed

    /// The same ten-event swipe as the first case, doubled: 600pt against a
    /// 16pt cell is 37 whole cells with 8pt carried.
    func testFastDoublesTheCellsAPreciseSwipeCrosses() {
        var accumulator = ScrollAccumulator()
        var total = 0
        for _ in 0..<10 {
            total += accumulator.add(deltaX: 0, deltaY: 30, precise: true, cellSize: cell, speed: .fast).y
        }
        XCTAssertEqual(total, 37)
        XCTAssertEqual(accumulator.pendingY, 8, accuracy: 0.0001)
    }

    /// The slowest step halves a notch rather than swallowing it, so the
    /// second notch of a pair is the one that crosses the cell.
    func testSlowHalvesANotchAndThePairStillCrossesACell() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 1, precise: false, cellSize: cell, speed: .slow).y, 0)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 1, precise: false, cellSize: cell, speed: .slow).y, 1)
    }

    /// The factor is taken after the slow-click round-out, so macOS's 0.1
    /// magnitude is a whole notch at the chosen speed rather than a tenth of
    /// one scaled back up.
    func testADiscreteNotchCarriesTheSpeedInWholeLines() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 1, precise: false, cellSize: cell, speed: .fast).y, 2)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 0.1, precise: false, cellSize: cell, speed: .fastest).y, 4)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -1, precise: false, cellSize: cell, speed: .fastest).y, -4)
    }

    func testHorizontalMotionTakesTheSameFactorAsVertical() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 20, deltaY: 0, precise: true, cellSize: cell, speed: .fast).x, 5)
        XCTAssertEqual(accumulator.pendingX, 0, accuracy: 0.0001)
        XCTAssertEqual(accumulator.add(deltaX: 2, deltaY: 0, precise: false, cellSize: cell, speed: .fast).x, 4)
    }

    /// The factor scales the event, never the remainder already carried, so a
    /// speed changed between two events leaves what was measured under the
    /// old one exactly as it was.
    func testAChangedSpeedLeavesTheCarriedRemainderAlone() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 10, precise: true, cellSize: cell, speed: .normal).y, 0)
        XCTAssertEqual(accumulator.pendingY, 10, accuracy: 0.0001)
        // The carried 10 plus 6 at double is 22: one cell, with 6 left.
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 6, precise: true, cellSize: cell, speed: .fast).y, 1)
        XCTAssertEqual(accumulator.pendingY, 6, accuracy: 0.0001)
    }
}
