import XCTest
import GhosttyKit
@testable import FlockCore

final class GhosttyMouseButtonsTests: XCTestCase {
    func testPrimaryButtons() {
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 0), GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 1), GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 2), GHOSTTY_MOUSE_MIDDLE)
    }

    /// AppKit's 3 and 4 are the physical back/forward buttons; xterm's 4-7
    /// are wheel directions, so they land on EIGHT/NINE, as in ghostty's own
    /// macOS host.
    func testBackAndForwardSkipTheWheelNumbers() {
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 3), GHOSTTY_MOUSE_EIGHT)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 4), GHOSTTY_MOUSE_NINE)
    }

    func testRemainingButtonsFollowTheReferenceTable() {
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 5), GHOSTTY_MOUSE_SIX)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 6), GHOSTTY_MOUSE_SEVEN)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 7), GHOSTTY_MOUSE_FOUR)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 8), GHOSTTY_MOUSE_FIVE)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 9), GHOSTTY_MOUSE_TEN)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 10), GHOSTTY_MOUSE_ELEVEN)
    }

    func testOutOfRangeIsUnknown() {
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: 11), GHOSTTY_MOUSE_UNKNOWN)
        XCTAssertEqual(GhosttyMouseButtons.translate(buttonNumber: -1), GHOSTTY_MOUSE_UNKNOWN)
    }
}
