import XCTest
@testable import FlockCore

final class ChatPresenceTests: XCTestCase {
    private func status(signedIn: Bool) -> ChatStatus {
        ChatStatus(handle: signedIn ? "kay" : nil, state: signedIn ? "live" : "not signed in",
                   pane: "w1:p1", signedIn: signedIn, rooms: signedIn ? ["#rt"] : [])
    }

    func testSignedOutPaneShowsSignInEnabled() {
        XCTAssertEqual(ChatPresence.signAction(for: status(signedIn: false)), .signIn(enabled: true))
    }

    func testSignedInPaneShowsSignOut() {
        XCTAssertEqual(ChatPresence.signAction(for: status(signedIn: true)), .signOut)
    }

    /// An unknown pane is not a signed-out pane: the control must not invite
    /// an action whose outcome nobody has established yet.
    func testUnknownStatusShowsSignInDisabled() {
        XCTAssertEqual(ChatPresence.signAction(for: nil), .signIn(enabled: false))
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
