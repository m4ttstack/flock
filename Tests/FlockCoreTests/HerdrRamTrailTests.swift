import XCTest
@testable import FlockCore

final class HerdrRamTrailTests: XCTestCase {
    func testEachEchoStartsLaterThanTheOneClosestToTheLeader() {
        let delays = HerdrRamTrail.echoes.map(\.startDelay)

        XCTAssertEqual(delays, [0, 0.035, 0.07])
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

    /// The composition is the leader plus the farthest echo's rest offset,
    /// and it is that union -- not the leader alone -- that has to fit and
    /// sit centred. Sizing or centring on the leader alone is what put the
    /// mark high and right of the pane's middle and pushed the farthest echo
    /// toward the frame.
    private func compositeBounds(in square: CGSize) -> CGRect {
        let leader = HerdrRamTrail.path(in: square).boundingBoxOfPath
        let spread = HerdrRamTrail.offset(restBackSteps: CGFloat(HerdrRamTrail.echoCount), in: square, progress: 0)
        return leader.union(leader.offsetBy(dx: spread.width, dy: spread.height))
    }

    func testTheWholeCompositionFitsInsideTheSquareItIsGiven() {
        for square in [CGSize(width: 96, height: 96), CGSize(width: 128, height: 128), CGSize(width: 220, height: 220)] {
            let composite = compositeBounds(in: square)

            XCTAssertTrue(
                CGRect(origin: .zero, size: square).insetBy(dx: -1, dy: -1).contains(composite),
                "composition \(composite) escaped \(square)"
            )
            XCTAssertGreaterThan(composite.width, 0)
        }
    }

    func testTheWholeCompositionIsCentredInTheSquare() {
        let square = CGSize(width: 128, height: 128)

        let composite = compositeBounds(in: square)

        XCTAssertEqual(composite.midX, square.width / 2, accuracy: 0.5)
        XCTAssertEqual(composite.midY, square.height / 2, accuracy: 0.5)
    }

    /// The ram used to be fit inside the app icon's squircle inset and
    /// margin, which left it occupying under half the box it was given. On a
    /// pane there is no squircle, so the composition fills what it is given,
    /// up to the one axis that binds -- the echoes step back further
    /// horizontally than vertically, so width runs out first and the height
    /// lands short of the full square.
    func testTheCompositionFillsTheSquareOnTheAxisThatBinds() {
        let square = CGSize(width: 128, height: 128)

        let composite = compositeBounds(in: square)

        XCTAssertGreaterThan(composite.width / square.width, 0.9)
        XCTAssertGreaterThan(composite.height / square.height, 0.75)
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
