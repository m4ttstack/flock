import XCTest
@testable import FlockCore

final class LaneSplitTests: XCTestCase {
    private func split(_ top: CGFloat, _ bottom: CGFloat, in height: CGFloat, floors: (CGFloat, CGFloat) = (60, 60)) -> LaneSplit.Allocation {
        LaneSplit.allocate(top: top, bottom: bottom, height: height, topFloor: floors.0, bottomFloor: floors.1)
    }

    func testBothFittingKeepTheirOwnHeightsAndNeitherScrolls() {
        XCTAssertEqual(split(200, 150, in: 600), .init(top: 200, bottom: 150, topScrolls: false, bottomScrolls: false))
        XCTAssertEqual(split(300, 300, in: 600), .init(top: 300, bottom: 300, topScrolls: false, bottomScrolls: false), "exactly full")
    }

    func testOneUnderItsHalfKeepsItsHeightAndTheOtherScrollsInTheRest() {
        XCTAssertEqual(split(120, 900, in: 600), .init(top: 120, bottom: 480, topScrolls: false, bottomScrolls: true))
        XCTAssertEqual(split(900, 120, in: 600), .init(top: 480, bottom: 120, topScrolls: true, bottomScrolls: false))
    }

    func testBothOverTheirHalfGetHalfEachAndBothScroll() {
        XCTAssertEqual(split(700, 900, in: 600), .init(top: 300, bottom: 300, topScrolls: true, bottomScrolls: true))
    }

    func testOneSubgroupAloneTakesAllTheHeight() {
        XCTAssertEqual(split(900, 0, in: 600), .init(top: 600, bottom: 0, topScrolls: true, bottomScrolls: false))
        XCTAssertEqual(split(0, 200, in: 600), .init(top: 0, bottom: 200, topScrolls: false, bottomScrolls: false))
        XCTAssertEqual(split(0, 0, in: 600), .init(top: 0, bottom: 0, topScrolls: false, bottomScrolls: false))
    }

    func testAFloorHoldsItsLabelAndFirstCardAgainstAnUnevenSplit() {
        XCTAssertEqual(
            split(500, 500, in: 100, floors: (70, 20)),
            .init(top: 70, bottom: 30, topScrolls: true, bottomScrolls: true), "half would cut the top's first card"
        )
        XCTAssertEqual(
            split(500, 500, in: 100, floors: (20, 70)),
            .init(top: 30, bottom: 70, topScrolls: true, bottomScrolls: true)
        )
    }

    func testWhenBothFloorsCannotFitTheTopOneWins() {
        XCTAssertEqual(split(500, 500, in: 100), .init(top: 60, bottom: 40, topScrolls: true, bottomScrolls: true))
        XCTAssertEqual(split(500, 500, in: 40), .init(top: 40, bottom: 0, topScrolls: true, bottomScrolls: true))
    }

    func testAFloorNeverExceedsTheSubgroupsOwnHeight() {
        XCTAssertEqual(
            split(30, 500, in: 100, floors: (60, 60)),
            .init(top: 30, bottom: 70, topScrolls: false, bottomScrolls: true)
        )
    }
}
