import XCTest
@testable import FlockCore

final class HerdrRamTrailTests: XCTestCase {
    func testEachEchoStartsLaterThanTheOneClosestToTheLeader() {
        let delays = HerdrRamTrail.echoes.map(\.startDelay)

        XCTAssertEqual(delays, [0, 0.05, 0.1])
    }

    /// Mirrors `make-icon.swift`'s own `back` and alpha: the farthest echo
    /// steps back the most and is the most transparent.
    func testRestGeometryMatchesTheIconsOwnNumbers() {
        XCTAssertEqual(HerdrRamTrail.echoes.map(\.restBackSteps), [3, 2, 1])
        for (opacity, expected) in zip(HerdrRamTrail.echoes.map(\.restOpacity), [0.58, 0.71, 0.84]) {
            XCTAssertEqual(opacity, expected, accuracy: 0.0001)
        }
    }

    func testOffsetAtRestMatchesTheStepFractionsTimesBackSteps() {
        let square = CGSize(width: 128, height: 128)

        let offset = HerdrRamTrail.offset(restBackSteps: 3, in: square, progress: 0)

        XCTAssertEqual(offset.width, 128 * 0.105 * 3, accuracy: 0.0001)
        XCTAssertEqual(offset.height, 128 * 0.075 * 3, accuracy: 0.0001)
    }

    func testOffsetAtFullMergeIsZeroRegardlessOfBackSteps() {
        let square = CGSize(width: 128, height: 128)

        let offset = HerdrRamTrail.offset(restBackSteps: 3, in: square, progress: 1)

        XCTAssertEqual(offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(offset.height, 0, accuracy: 0.0001)
    }

    func testPathFitsInsideTheSquareItIsGiven() {
        let square = CGSize(width: 128, height: 128)

        let bounds = HerdrRamTrail.path(in: square).boundingBoxOfPath

        XCTAssertTrue(CGRect(origin: .zero, size: square).insetBy(dx: -1, dy: -1).contains(bounds))
        XCTAssertGreaterThan(bounds.width, 0)
    }

    func testAnOffsetPathTranslatesWithoutChangingSize() {
        let square = CGSize(width: 128, height: 128)
        let rest = HerdrRamTrail.path(in: square).boundingBoxOfPath
        let shifted = HerdrRamTrail.path(in: square, dx: 10, dy: -6).boundingBoxOfPath

        XCTAssertEqual(shifted.width, rest.width, accuracy: 0.0001)
        XCTAssertEqual(shifted.height, rest.height, accuracy: 0.0001)
        XCTAssertEqual(shifted.minX - rest.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(shifted.minY - rest.minY, -6, accuracy: 0.0001)
    }
}
