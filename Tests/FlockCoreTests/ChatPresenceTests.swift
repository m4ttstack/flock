import XCTest
@testable import FlockCore

final class ChatPresenceTests: XCTestCase {
    private func status(signedIn: Bool) -> ChatStatus {
        ChatStatus(handle: signedIn ? "kay" : nil, state: signedIn ? "live" : "not signed in",
                   pane: "w1:p1", signedIn: signedIn, rooms: signedIn ? ["#rt"] : [])
    }

    func testSignInLeadsWhenThePaneIsNotSignedIn() {
        let buttons = ChatPresence.buttons(for: status(signedIn: false))
        XCTAssertEqual(buttons.signIn, .primary)
        XCTAssertEqual(buttons.signOut, .secondary)
    }

    func testSignOutLeadsOnceThePaneIsSignedIn() {
        let buttons = ChatPresence.buttons(for: status(signedIn: true))
        XCTAssertEqual(buttons.signOut, .primary)
        XCTAssertEqual(buttons.signIn, .secondary)
    }

    /// A pane that is not signed in cannot send, and the compose footer says
    /// why rather than letting the user type and then fail.
    func testSendingNeedsASignedInPane() {
        XCTAssertFalse(ChatPresence.canSend(status(signedIn: false)))
        XCTAssertTrue(ChatPresence.canSend(status(signedIn: true)))
    }

    /// No status yet is not the same as signed out, but it is equally unable
    /// to send.
    func testAnUnknownStatusCannotSend() {
        XCTAssertFalse(ChatPresence.canSend(nil))
    }
}
