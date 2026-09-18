import XCTest
import GhosttyKit
@testable import FlockCore

/// The rule in one line: the user asking gets the clipboard, a program asking
/// does not, and everything gets an answer.
final class ClipboardReadDispositionTests: XCTestCase {
    func testAPasteIsTheUsersOwnRequestAndGetsTheClipboard() {
        XCTAssertEqual(ClipboardReadDisposition.decide(GHOSTTY_CLIPBOARD_REQUEST_PASTE), .allow)
    }

    func testAnOSC52ReadIsAProgramsRequestAndIsDenied() {
        XCTAssertEqual(ClipboardReadDisposition.decide(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ), .deny)
    }

    func testAnOSC52WriteIsDenied() {
        XCTAssertEqual(ClipboardReadDisposition.decide(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE), .deny)
    }

    /// The decision has to be total. A request kind this build does not know
    /// still holds a libghostty allocation that only a completion frees, so
    /// there is no "no answer" branch for the callback to take.
    func testARequestKindThisBuildDoesNotKnowIsDenied() {
        XCTAssertEqual(ClipboardReadDisposition.decide(ghostty_clipboard_request_e(rawValue: 99)), .deny)
    }
}
