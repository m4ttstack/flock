import XCTest
@testable import FlockCore

final class ChatVerbTests: XCTestCase {
    func testStatusNamesThePaneItAsksAbout() {
        XCTAssertEqual(
            ChatVerb.status(pane: "w1:p1").arguments,
            ["status", "--json", "--pane", "w1:p1"]
        )
    }

    /// The panes are one comma-separated argument, which is what the verb's
    /// own value delimiter expects; one flag per pane is a different CLI.
    func testBroadcastJoinsItsPanesIntoOneArgument() {
        XCTAssertEqual(
            ChatVerb.broadcast(panes: ["w1:p1", "w2:p7"], body: "pausing").arguments,
            ["broadcast", "--json", "--panes", "w1:p1,w2:p7", "--body", "pausing"]
        )
    }

    /// A room is passed with its prefix, because the far side refuses a bare
    /// name rather than guessing between a room and a person.
    func testQuickSendPassesTheTargetPrefixThrough() {
        XCTAssertEqual(
            ChatVerb.quickSend(to: "#rt", body: "hi").arguments,
            ["quick-send", "--json", "--to", "#rt", "--body", "hi"]
        )
    }

    func testOpenViewerOmitsTheRoomFlagWhenThereIsNoRoom() {
        XCTAssertEqual(ChatVerb.openViewer(room: nil).arguments, ["open-viewer", "--json"])
        XCTAssertEqual(
            ChatVerb.openViewer(room: "rt").arguments,
            ["open-viewer", "--json", "--room", "rt"]
        )
    }

    /// A body is never shell-quoted here: `Process` takes an argument vector,
    /// so a body holding spaces, quotes or a leading dash is one argument and
    /// needs no escaping. Quoting it would send the quotes.
    func testABodyWithShellMetacharactersIsOneUnescapedArgument() {
        let body = "don't \"ship\"; --now"
        XCTAssertEqual(ChatVerb.quickSend(to: "@scout", body: body).arguments.last, body)
    }
}
