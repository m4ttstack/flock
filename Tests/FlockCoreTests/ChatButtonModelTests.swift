import AppKit
import XCTest
@testable import FlockCore

final class ChatButtonModelTests: XCTestCase {
    private func status(signedIn: Bool, handle: String? = "@kay") -> ChatStatus {
        ChatStatus(
            handle: signedIn ? handle : nil, state: signedIn ? "live" : "not signed in",
            pane: "w1:p1", signedIn: signedIn, rooms: signedIn ? ["#rt"] : []
        )
    }

    func testNoBinaryIsAbsentRegardlessOfStatus() {
        XCTAssertEqual(
            ChatButtonModel.appearance(availability: false, status: status(signedIn: true), unread: 3), .absent
        )
        XCTAssertEqual(ChatButtonModel.appearance(availability: false, status: nil, unread: 0), .absent)
    }

    /// The boundary a caller must never collapse: chat exists on this machine
    /// but the status probe has not answered for this pane yet. That reads as
    /// signed out, not as absent.
    func testAvailableWithNoStatusYetReadsAsSignedOut() {
        XCTAssertEqual(ChatButtonModel.appearance(availability: true, status: nil, unread: 0), .signedOut)
    }

    func testSignedOutStatusReadsAsSignedOut() {
        XCTAssertEqual(
            ChatButtonModel.appearance(availability: true, status: status(signedIn: false), unread: 0), .signedOut
        )
    }

    func testSignedInStatusCarriesTheHandleAndUnreadCount() {
        XCTAssertEqual(
            ChatButtonModel.appearance(availability: true, status: status(signedIn: true, handle: "@kay"), unread: 3),
            .signedIn(handle: "kay", unread: 3)
        )
    }

    /// The design's own handle drops the `@` rt prints; a handle with none
    /// already (defensive: rt is not guaranteed to always send one) passes
    /// through unchanged rather than losing a character.
    func testSignedInHandleDropsTheLeadingAtSignRtPrints() {
        XCTAssertEqual(
            ChatButtonModel.appearance(availability: true, status: status(signedIn: true, handle: "kay"), unread: 0),
            .signedIn(handle: "kay", unread: 0)
        )
    }

    /// A typo'd symbol name resolves to nothing, silently -- this is the one
    /// guard that catches it before it ships as an invisible glyph.
    func testTheChatGlyphSymbolResolves() {
        XCTAssertNotNil(NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil))
    }
}
