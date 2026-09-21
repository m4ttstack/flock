import XCTest
@testable import FlockCore

final class PaneLoaderChoreographyTests: XCTestCase {
    /// `PaneLoaderPolicyTests` owns how this lines up with the display
    /// floor, since the floor is what is derived from it.
    func testOneLoopIsJustOverASecond() {
        XCTAssertEqual(PaneLoaderChoreography.loopDuration, 1.05, accuracy: 0.0001)
    }

    func testFullySeparatedAtTheStartOfItsOwnCycle() {
        XCTAssertEqual(PaneLoaderChoreography.mergeProgress(elapsed: 0, startDelay: 0), 0, accuracy: 0.0001)
    }

    func testFullyMergedTheInstantGatheringCompletes() {
        let progress = PaneLoaderChoreography.mergeProgress(
            elapsed: PaneLoaderChoreography.gatherDuration, startDelay: 0
        )

        XCTAssertEqual(progress, 1, accuracy: 0.0001)
    }

    func testStaysMergedThroughTheWholeHold() {
        let midHold = PaneLoaderChoreography.gatherDuration + PaneLoaderChoreography.holdDuration / 2

        XCTAssertEqual(PaneLoaderChoreography.mergeProgress(elapsed: midHold, startDelay: 0), 1, accuracy: 0.0001)
    }

    func testFullySeparatedAgainByTheEndOfTheDrift() {
        // The loop wraps here, so this instant reads the same as elapsed 0.
        let progress = PaneLoaderChoreography.mergeProgress(
            elapsed: PaneLoaderChoreography.loopDuration, startDelay: 0
        )

        XCTAssertEqual(progress, 0, accuracy: 0.0001)
    }

    func testAStaggeredEchoLagsAnUnstaggeredOneAtTheSameInstant() {
        let leading = PaneLoaderChoreography.mergeProgress(elapsed: 0.2, startDelay: 0)
        let staggered = PaneLoaderChoreography.mergeProgress(elapsed: 0.2, startDelay: HerdrRamTrail.staggerDelay)

        XCTAssertGreaterThan(leading, staggered)
    }

    func testNegativeElapsedWrapsForwardRatherThanGoingNegative() {
        // A sample taken just before an echo's own start delay must land in
        // the tail of the PREVIOUS loop, not at a negative, meaningless time.
        let progress = PaneLoaderChoreography.mergeProgress(elapsed: 0, startDelay: HerdrRamTrail.staggerDelay)

        XCTAssertGreaterThanOrEqual(progress, 0)
        XCTAssertLessThanOrEqual(progress, 1)
    }
}
