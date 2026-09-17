import CoreGraphics
import XCTest
@testable import FlockCore

final class ScrolledItemFramesTests: XCTestCase {
    private func twoRows() -> ScrolledItemFrames<String> {
        var frames = ScrolledItemFrames<String>()
        frames.setOrder(["a", "b"])
        frames.setContentFrame(CGRect(x: 10, y: 0, width: 170, height: 27), for: "a")
        frames.setContentFrame(CGRect(x: 10, y: 28, width: 170, height: 27), for: "b")
        return frames
    }

    func testOnScreenFramesAreContentFramesMovedByTheContentOrigin() {
        var frames = twoRows()
        frames.setContentOrigin(CGPoint(x: 0, y: 26))
        XCTAssertEqual(frames.onScreen.map(\.frame), [
            CGRect(x: 10, y: 26, width: 170, height: 27),
            CGRect(x: 10, y: 54, width: 170, height: 27),
        ])
    }

    /// A scroll is an origin report alone: no item reports again, yet every
    /// on-screen frame moves with it.
    func testScrollingMovesEveryOnScreenFrameWithNoItemReporting() {
        var frames = twoRows()
        frames.setContentOrigin(CGPoint(x: 0, y: 26))
        frames.setContentOrigin(CGPoint(x: 0, y: -40))
        XCTAssertEqual(frames.onScreen.map(\.frame.minY), [-40, -12])
    }

    func testOnScreenFollowsOrderAndSkipsItemsWithNoFrameYet() {
        var frames = twoRows()
        frames.setOrder(["b", "c", "a"])
        XCTAssertEqual(frames.onScreen.map(\.id), ["b", "a"])
    }

    func testAnItemThatLeavesAndReturnsHasNoStaleFrame() {
        var frames = twoRows()
        frames.setOrder(["b"])
        frames.setOrder(["a", "b"])
        XCTAssertEqual(frames.onScreen.map(\.id), ["b"])
    }

    func testSettersReportWhetherAnythingChanged() {
        var frames = twoRows()
        XCTAssertFalse(frames.setOrder(["a", "b"]))
        XCTAssertFalse(frames.setContentFrame(CGRect(x: 10, y: 0, width: 170, height: 27), for: "a"))
        XCTAssertTrue(frames.setContentOrigin(CGPoint(x: 0, y: 1)))
        XCTAssertFalse(frames.setContentOrigin(CGPoint(x: 0, y: 1)))
    }
}
