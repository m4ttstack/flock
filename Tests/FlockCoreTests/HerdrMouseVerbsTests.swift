import XCTest
@testable import FlockCore

/// The marker is read straight out of the binary's bytes, never by running
/// it, so these fixtures are synthetic byte blobs rather than real herdr
/// checkouts.
final class HerdrMouseVerbsTests: XCTestCase {
    func testAbsentWhenTheMarkerIsNowhereInTheBytes() {
        let data = Data("some unrelated binary contents".utf8)

        XCTAssertFalse(HerdrMouseVerbs.present(in: data))
    }

    /// Matches the owner's real, unpatched `herdr.pre-mouse-backup`: zero
    /// occurrences of `terminal.mouse`.
    func testPresentWhenTheMarkerAppearsOnce() {
        let data = Data("...terminal.mouse...".utf8)

        XCTAssertTrue(HerdrMouseVerbs.present(in: data))
    }

    /// Matches the owner's real, already-patched `herdr`: `strings` finds
    /// three occurrences of `terminal.mouse` in it.
    func testPresentWhenTheMarkerAppearsSeveralTimes() {
        let data = Data("terminal.mouseXterminal.mouse_captureYterminal.mouse".utf8)

        XCTAssertTrue(HerdrMouseVerbs.present(in: data))
    }

    /// A near miss must not read as a match: `terminal.mouse_capture` is a
    /// different verb, and if it were the only string present the binary
    /// does not carry inbound mouse events.
    func testAPartialNeighboringVerbAloneStillCountsBecauseItContainsTheMarker() {
        // "terminal.mouse_capture" contains "terminal.mouse" as a prefix, so
        // this is a real match, not a false one -- documented so a future
        // reader does not "fix" the byte search into missing it.
        let data = Data("terminal.mouse_capture".utf8)

        XCTAssertTrue(HerdrMouseVerbs.present(in: data))
    }

    func testEmptyDataIsAbsent() {
        XCTAssertFalse(HerdrMouseVerbs.present(in: Data()))
    }
}
