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

    private let tail = 34.0

    private func trail(at elapsed: Double) -> [PaneLoaderStride.TrailDot] {
        PaneLoaderStride.trail(elapsed: elapsed, start: start, badgeWidth: badge, boxWidth: box, tailOffset: tail)
    }

    /// Dropped off the back of the mark, never under it.
    func testTheFirstDotDropsBehindTheMark() throws {
        let first = try XCTUnwrap(trail(at: 0).first)

        XCTAssertEqual(first.x, start + tail, accuracy: 0.0001)
        XCTAssertGreaterThan(first.x, start + badge)
    }

    /// Dots stay where they dropped while the mark moves on, evenly spaced,
    /// newest nearest the mark and oldest faintest.
    func testDotsStayWhereTheyDropped() {
        let dots = trail(at: 3)

        XCTAssertEqual(dots.count, PaneLoaderStride.trailLength)
        for (older, newer) in zip(dots.dropFirst(), dots) {
            XCTAssertEqual(older.x - newer.x, PaneLoaderStride.dotSpacing, accuracy: 0.0001)
            XCTAssertLessThan(older.opacity, newer.opacity)
        }
    }

    /// The trail winds: across one wavelength it rises above and dips below
    /// the ground line, and each dot sits on the path where it dropped.
    func testTheTrailWindsUpAndDown() {
        let dots = trail(at: 2)

        XCTAssertTrue(dots.contains { $0.lift > PaneLoaderStride.windAmplitude / 2 })
        XCTAssertTrue(dots.contains { $0.lift < -PaneLoaderStride.windAmplitude / 2 })
        for dot in dots {
            XCTAssertEqual(dot.lift, PaneLoaderStride.winding(atX: dot.x), accuracy: 0.0001)
        }
    }
}
