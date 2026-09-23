import XCTest
@testable import FlockCore

final class PaneLoaderStrideTests: XCTestCase {
    private let box = 600.0
    private let badge = 32.0
    private let start = 556.0

    /// It first appears exactly where the resting badge used to sit.
    func testTheRunStartsWhereTheBadgeRests() {
        XCTAssertEqual(PaneLoaderStride.leadingX(elapsed: 0, start: start, badgeWidth: badge, boxWidth: box), start, accuracy: 0.0001)
    }

    /// Leftward, the way the ram faces.
    func testTheBadgeRunsLeft() {
        let later = PaneLoaderStride.leadingX(elapsed: 0.5, start: start, badgeWidth: badge, boxWidth: box)

        XCTAssertEqual(later, start - PaneLoaderStride.speed * 0.5, accuracy: 0.0001)
    }

    func testOnceFullyPastTheLeftEdgeItReentersFromBeyondTheRight() {
        let exit = -(badge + PaneLoaderStride.overscan)
        let toExit = (start - exit) / PaneLoaderStride.speed

        let justBefore = PaneLoaderStride.leadingX(elapsed: toExit - 0.001, start: start, badgeWidth: badge, boxWidth: box)
        let justAfter = PaneLoaderStride.leadingX(elapsed: toExit + 0.001, start: start, badgeWidth: badge, boxWidth: box)

        XCTAssertEqual(justBefore, exit, accuracy: 0.2)
        XCTAssertEqual(justAfter, box + PaneLoaderStride.overscan, accuracy: 0.2)
    }

    func testTheMarkStartsOnTheGround() {
        XCTAssertEqual(PaneLoaderStride.hopLift(elapsed: 0), 0, accuracy: 0.0001)
    }

    func testAHopPeaksHalfwayAndLandsAtItsEnd() {
        let half = PaneLoaderStride.hopDuration / 2

        XCTAssertEqual(PaneLoaderStride.hopLift(elapsed: half), 1, accuracy: 0.0001)
        XCTAssertEqual(PaneLoaderStride.hopLift(elapsed: PaneLoaderStride.hopDuration), 0, accuracy: 0.0001)
    }

    func testTheFirstLandingIsMarkedWhereTheRunStarts() {
        let prints = PaneLoaderStride.hoofprints(elapsed: 0, start: start, badgeWidth: badge, boxWidth: box)

        XCTAssertEqual(prints, [.init(leadingX: start, opacity: 1)])
    }

    /// Prints stay where they were made while the mark moves on, one per
    /// landing, newest nearest the mark.
    func testEachLandingLeavesAPrintBehindTheMark() {
        let hop = PaneLoaderStride.hopDuration
        let prints = PaneLoaderStride.hoofprints(elapsed: 2.5 * hop, start: start, badgeWidth: badge, boxWidth: box)

        XCTAssertEqual(prints.count, 3)
        for (print, expected) in zip(prints, [2.0, 1.0, 0.0]) {
            XCTAssertEqual(print.leadingX, start - PaneLoaderStride.speed * expected * hop, accuracy: 0.0001)
        }
        XCTAssertTrue(zip(prints, prints.dropFirst()).allSatisfy { $0.opacity > $1.opacity }, "older prints should be fainter")
    }

    func testTheTrailKeepsOnlyItsLength() {
        let prints = PaneLoaderStride.hoofprints(elapsed: 40, start: start, badgeWidth: badge, boxWidth: box)

        XCTAssertEqual(prints.count, PaneLoaderStride.trailLength)
        XCTAssertTrue(prints.allSatisfy { $0.opacity > 0 && $0.opacity <= 1 })
    }
}
