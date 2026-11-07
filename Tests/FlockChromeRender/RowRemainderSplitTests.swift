import XCTest

final class RowRemainderSplitTests: XCTestCase {
    func testTheUnfilledPartOfARowSplitsAboveAndBelow() {
        XCTAssertEqual(RowRemainderSplit.offset(available: 120, surfaceHeight: 100), 10)
    }

    /// An odd remainder rounds down to a whole point, so the surface keeps
    /// the pixel grid the box was snapped to.
    func testAnOddRemainderRoundsDownToAWholePoint() {
        XCTAssertEqual(RowRemainderSplit.offset(available: 117, surfaceHeight: 100), 8)
        XCTAssertEqual(RowRemainderSplit.offset(available: 100.6, surfaceHeight: 100), 0)
    }

    func testASurfaceTallerThanItsRoomIsNeverPushedUp() {
        XCTAssertEqual(RowRemainderSplit.offset(available: 90, surfaceHeight: 100), 0)
        XCTAssertEqual(RowRemainderSplit.offset(available: 100, surfaceHeight: 100), 0)
    }
}
