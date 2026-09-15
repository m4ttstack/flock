import XCTest
@testable import PaddockCore

final class BridgeFrameGateTests: XCTestCase {
    private let grid = PTYSize(cols: 80, rows: 24)
    private let narrower = PTYSize(cols: 60, rows: 24)

    private func frame(_ size: PTYSize?, full: Bool) -> HerdrFrame {
        HerdrFrame(bytes: Data("x".utf8), size: size, full: full)
    }

    // MARK: - stale frames

    func testAFrameAtTheDeclaredGridIsWritten() {
        var gate = BridgeFrameGate(declared: grid)

        let result = gate.frame(frame(grid, full: false), surface: grid)

        XCTAssertTrue(result.write)
        XCTAssertEqual(result.effects, BridgeFrameGate.Effects())
    }

    func testAFrameForAnotherGridIsNotWritten() {
        var gate = BridgeFrameGate(declared: grid)

        XCTAssertFalse(gate.frame(frame(narrower, full: true), surface: grid).write)
    }

    func testTheFirstDropRequestsExactlyOneRepaintAtTheDeclaredGrid() {
        var gate = BridgeFrameGate(declared: grid)

        let result = gate.frame(frame(narrower, full: false), surface: grid)

        XCTAssertEqual(result.effects.resize, grid)
        XCTAssertEqual(gate.repaint, .requested)
    }

    func testABurstOfDropsRequestsOneRepaint() {
        var gate = BridgeFrameGate(declared: grid)

        let resizes = (0..<5).compactMap { _ in gate.frame(frame(narrower, full: false), surface: grid).effects.resize }

        XCTAssertEqual(resizes, [grid])
    }

    func testAFullFrameAtTheDeclaredGridAfterADropIsWrittenAndClearsThePendingRepaint() {
        var gate = BridgeFrameGate(declared: grid)
        _ = gate.frame(frame(narrower, full: false), surface: grid)

        XCTAssertTrue(gate.frame(frame(grid, full: true), surface: grid).write)
        XCTAssertEqual(gate.repaint, .none)
        XCTAssertEqual(
            gate.frame(frame(narrower, full: false), surface: grid).effects.resize, grid,
            "once cleared, a later drop owes a repaint of its own")
    }

    /// herdr's diff baseline is the dropped frame, so an incremental frame
    /// after a drop describes cells the surface never received.
    func testAnIncrementalFrameAfterADropIsHeldBackUntilAFullOneLands() {
        var gate = BridgeFrameGate(declared: grid)
        _ = gate.frame(frame(narrower, full: false), surface: grid)

        XCTAssertFalse(gate.frame(frame(grid, full: false), surface: grid).write)
        XCTAssertTrue(gate.frame(frame(grid, full: true), surface: grid).write)
        XCTAssertTrue(gate.frame(frame(grid, full: false), surface: grid).write)
    }

    func testAFrameWithoutASizeOrBeforeAnyGridIsDeclaredIsWritten() {
        var gate = BridgeFrameGate(declared: grid)
        XCTAssertTrue(gate.frame(frame(nil, full: false), surface: narrower).write)

        var undeclared = BridgeFrameGate()
        XCTAssertTrue(undeclared.frame(frame(narrower, full: false), surface: grid).write)
    }

    // MARK: - the surface lagging a declared grid

    func testAFrameForTheNewGridIsDroppedUntilThePTYReachesItThenOneRepaintIsSent() {
        var gate = BridgeFrameGate(declared: narrower)
        XCTAssertEqual(gate.declare(grid, repaint: false, surface: narrower).resize, grid)

        let early = gate.frame(frame(grid, full: true), surface: narrower)
        XCTAssertFalse(early.write, "libghostty would parse an 80-column frame into its 60-column terminal")
        XCTAssertNil(early.effects.resize, "a repaint sent now would race the same resize")

        XCTAssertEqual(gate.surfaceResized(surface: grid).resize, grid)
        XCTAssertNil(gate.surfaceResized(surface: grid).resize)
        XCTAssertTrue(gate.frame(frame(grid, full: true), surface: grid).write)
    }

    func testAnExpiredSurfaceWaitLetsFramesThroughAndSendsTheOwedRepaint() throws {
        var gate = BridgeFrameGate(declared: grid)
        let held = gate.frame(frame(grid, full: true), surface: narrower)
        XCTAssertFalse(held.write)
        let token = try XCTUnwrap(held.effects.surfaceWait)

        XCTAssertNil(gate.surfaceWaitExpired(token: token + 1, surface: narrower).resize, "a stale token changes nothing")
        XCTAssertEqual(gate.surfaceWaitExpired(token: token, surface: narrower).resize, grid)
        XCTAssertTrue(gate.frame(frame(grid, full: true), surface: narrower).write)
    }

    // MARK: - settle repaints

    func testASettleSendsTheUnchangedGridOnce() {
        var gate = BridgeFrameGate(declared: grid)

        XCTAssertEqual(gate.declare(grid, repaint: true, surface: grid).resize, grid)
        XCTAssertNil(gate.declare(grid, repaint: true, surface: grid).resize, "the repaint already in flight covers a second settle")
    }

    func testAnUnchangedGridWithoutARepaintSendsNothing() {
        var gate = BridgeFrameGate(declared: grid)

        XCTAssertNil(gate.declare(grid, repaint: false, surface: grid).resize)
    }

    func testASettleWaitsForThePTYToReachTheGrid() {
        var gate = BridgeFrameGate(declared: grid)

        XCTAssertNil(gate.declare(grid, repaint: true, surface: narrower).resize)
        XCTAssertEqual(gate.surfaceResized(surface: grid).resize, grid)
    }

    func testADropAndASettleCloseTogetherSendOneRepaintInEitherOrder() {
        var dropFirst = BridgeFrameGate(declared: grid)
        let dropped = dropFirst.frame(frame(narrower, full: false), surface: grid).effects.resize
        let settled = dropFirst.declare(grid, repaint: true, surface: grid).resize
        XCTAssertEqual([dropped, settled].compactMap { $0 }, [grid])

        var settleFirst = BridgeFrameGate(declared: grid)
        let settledFirst = settleFirst.declare(grid, repaint: true, surface: grid).resize
        let droppedAfter = settleFirst.frame(frame(narrower, full: false), surface: grid).effects.resize
        XCTAssertEqual([settledFirst, droppedAfter].compactMap { $0 }, [grid])
    }

    /// herdr repaints in full on any resize, so the grid change's own send is
    /// the repaint when the surface is already there.
    func testAGridChangeWithTheSurfaceAlreadyThereSendsOneResizeForBoth() {
        var gate = BridgeFrameGate(declared: narrower)

        XCTAssertEqual(gate.declare(grid, repaint: true, surface: grid).resize, grid)
        XCTAssertEqual(gate.repaint, .requested)
    }

    // MARK: - never left waiting

    func testANewGridWhileARepaintIsRequestedOwesItAgainAtTheNewGrid() {
        var gate = BridgeFrameGate(declared: narrower)
        _ = gate.frame(frame(grid, full: false), surface: narrower)
        XCTAssertEqual(gate.repaint, .requested)

        XCTAssertEqual(gate.declare(grid, repaint: false, surface: narrower).resize, grid)
        XCTAssertEqual(gate.repaint, .owed)
        XCTAssertEqual(gate.surfaceResized(surface: grid).resize, grid)
    }

    func testADroppedFullFrameWhileARepaintIsRequestedOwesItAgain() {
        var gate = BridgeFrameGate(declared: grid)
        _ = gate.declare(grid, repaint: true, surface: grid)

        let answer = gate.frame(frame(grid, full: true), surface: narrower)

        XCTAssertFalse(answer.write)
        XCTAssertEqual(gate.repaint, .owed)
        XCTAssertEqual(gate.surfaceResized(surface: grid).resize, grid)
    }
}
