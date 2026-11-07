import FlockCore
import XCTest

final class ChatSidebarTests: XCTestCase {
    private func chat(_ room: String, pane: String? = nil, linked: String? = nil) -> ChatSidebarChat {
        ChatSidebarChat(room: room, pane: pane, name: room, linkedPane: linked)
    }

    func testAnUnansweredListIsNotAnEmptyOne() {
        XCTAssertNil(ChatSidebarChats.decode(stdout: Data(), exitCode: 1))
        XCTAssertNil(ChatSidebarChats.decode(stdout: Data("nope".utf8), exitCode: 0))
        XCTAssertEqual(ChatSidebarChats.decode(stdout: Data(#"{"conversations":[]}"#.utf8), exitCode: 0), [])
    }

    func testTheDisplayNameWinsUnlessItIsEmpty() {
        XCTAssertEqual(ChatSidebarChat(room: "r", name: "slack.u1", displayName: "Alex Example").shownName, "Alex Example")
        XCTAssertEqual(ChatSidebarChat(room: "r", name: "slack.u1", displayName: "").shownName, "slack.u1")
    }

    func testALinkedPaneIsTheChatsHome() {
        XCTAssertEqual(chat("a", pane: "bg:w1:p1", linked: "w2:p3").homePane, "w2:p3")
        XCTAssertEqual(chat("a", pane: "w2:p3").homePane, "w2:p3")
    }

    func testAnUnlinkedBackgroundChatShowsOnNoTab() {
        let selection = ChatSidebarSelection(chat: chat("a", pane: "bg:w1:p1"), isEnded: false)
        XCTAssertFalse(selection.isLinked(toTab: ["w2:p3"]))
    }

    func testAChatWithNoPaneShowsOnNoTab() {
        let selection = ChatSidebarSelection(chat: chat("a", pane: nil), isEnded: false)
        XCTAssertFalse(selection.isLinked(toTab: ["w2:p3"]))
    }

    func testALinkedChatShowsOnlyOnItsPanesTab() {
        let selection = ChatSidebarSelection(chat: chat("a", pane: "bg:w1:p1", linked: "w2:p3"), isEnded: false)
        XCTAssertTrue(selection.isLinked(toTab: ["w2:p3"]))
        XCTAssertFalse(selection.isLinked(toTab: ["w1:p1"]))
    }

    func testTheFocusedPanesChatWins() {
        let shown = ChatSidebarSelection(chat: chat("a", pane: "w1:p1"), isEnded: false)
        let next = ChatSidebarSelection.next(
            current: shown, open: [chat("a", pane: "w1:p1"), chat("b", pane: "w1:p2")],
            focusedPane: "w1:p2", tabPanes: ["w1:p1", "w1:p2"]
        )
        XCTAssertEqual(next?.chat.room, "b")
    }

    func testAPaneWithNoChatKeepsTheConversationBeingRead() {
        let shown = ChatSidebarSelection(chat: chat("a", pane: "w1:p1"), isEnded: false)
        let next = ChatSidebarSelection.next(
            current: shown, open: [chat("a", pane: "w1:p1"), chat("b", pane: "w1:p2")],
            focusedPane: "w1:p3", tabPanes: ["w1:p1", "w1:p2", "w1:p3"]
        )
        XCTAssertEqual(next?.chat.room, "a")
    }

    func testChangingTabsPicksThatTabsChatOverTheOneShown() {
        let shown = ChatSidebarSelection(chat: chat("a", pane: "w1:p1"), isEnded: false)
        let next = ChatSidebarSelection.next(
            current: shown, open: [chat("a", pane: "w1:p1"), chat("b", pane: "w2:p1")],
            focusedPane: "w2:p2", tabPanes: ["w2:p1", "w2:p2"]
        )
        XCTAssertEqual(next?.chat.room, "b")
    }

    func testAClosedChatStaysUntilItIsDismissed() {
        let shown = ChatSidebarSelection(chat: chat("a", pane: "w1:p1"), isEnded: false)
        let next = ChatSidebarSelection.next(current: shown, open: [], focusedPane: "w1:p1", tabPanes: ["w1:p1"])
        XCTAssertEqual(next, ChatSidebarSelection(chat: shown.chat, isEnded: true))
    }

    func testNothingOpenAndNothingShownIsNothing() {
        XCTAssertNil(ChatSidebarSelection.next(current: nil, open: [], focusedPane: nil, tabPanes: []))
    }

    private func decoded(_ conversation: String) throws -> ChatSidebarChat {
        let json = Data(#"{"conversations":[\#(conversation)]}"#.utf8)
        return try XCTUnwrap(ChatSidebarChats.decode(stdout: json, exitCode: 0)?.first)
    }

    func testAChatWithARequesterPaneShowsOnThatPanesTab() throws {
        let chat = try decoded(
            #"{"id":4,"room":"dm","pane":"bg:w9:p1","name":"alex","displayName":"Alex","requesterPane":"w2:p3"}"#
        )
        let selection = ChatSidebarSelection(chat: chat, isEnded: false)

        XCTAssertEqual(chat.homePane, "w2:p3")
        XCTAssertTrue(selection.isLinked(toTab: ["w2:p3"]))
        XCTAssertFalse(selection.isLinked(toTab: ["w1:p1"]))
    }

    func testALinkedPaneStillBeatsTheRequesterPane() {
        let chat = ChatSidebarChat(room: "a", pane: "bg:w1:p1", name: "a", linkedPane: "w2:p3", requesterPane: "w4:p4")
        XCTAssertEqual(chat.homePane, "w2:p3")
    }

    func testAChatListedByItsAssignedPaneHasThatPaneAsItsAgent() throws {
        let chat = try decoded(#"{"id":4,"room":"dm","name":"alex","assignedPane":"bg:w9:p2","requesterPane":"w2:p3"}"#)
        XCTAssertEqual(chat.agentPane, "bg:w9:p2")
        XCTAssertEqual(chat.id, 4)
        XCTAssertEqual(try decoded(#"{"room":"dm","pane":"bg:w9:p1","name":"alex","assignedPane":"bg:w9:p2"}"#).agentPane, "bg:w9:p1")
    }

    func testStartTakesTheBriefOnStdinSoItsArgumentsCarryNoProblem() {
        XCTAssertEqual(
            ChatSlackStart.arguments(person: "U0TEST", requesterPane: "w1:p2"),
            ["chat", "slack-start", "U0TEST", "--brief", "-", "--requester-pane", "w1:p2", "--json"]
        )
    }

    func testStartAndResumeRunWithNoCallerIdentity() {
        let environment = ChatSlackStart.environment(
            ["HERDR_PANE_ID": "w1:p9", "CLAUDE_CODE_SESSION_ID": "s", "PATH": "/opt/bin"]
        )
        XCTAssertEqual(environment, ["PATH": "/opt/bin"])
    }

    func testTheOutcomeIsTheConversationRtAnswersWith() {
        XCTAssertEqual(ChatSlackStart.outcome(stdout: Data(#"{"ok":true,"conversation":7}"#.utf8), exitCode: 0), .done)
        XCTAssertEqual(
            ChatSlackStart.outcome(stdout: Data(#"{"ok":false,"error":"already in a chat"}"#.utf8), exitCode: 1),
            .failed("already in a chat")
        )
        XCTAssertEqual(ChatSlackStart.outcome(stdout: Data(), exitCode: 1), .failed("rt gave no answer"))
        XCTAssertEqual(ChatSlackStart.outcome(stdout: Data(#"{"ok":true}"#.utf8), exitCode: 1), .failed("rt gave no answer"))
    }

    func testResumeNamesTheClosedChatAndTakesTheTapAsApproval() {
        XCTAssertEqual(ChatSlackResume.arguments(conversation: 7), ["chat", "slack-resume", "7", "--approved", "--json"])
    }

    func testARepoNamesItselfByItsFolder() {
        XCTAssertEqual(ChatSlackRepo(path: "/src/acme").name, "acme")
    }

    func testThePortComesFromTheChatRowOnlyWhileItIsUp() {
        let list = """
        board  11002  up    acme
        chat   11004  up    acme
        """
        XCTAssertEqual(ChatEmbedAddress.port(deckList: list), 11004)
        XCTAssertNil(ChatEmbedAddress.port(deckList: "chat 11004 down acme"))
        XCTAssertNil(ChatEmbedAddress.port(deckList: ""))
    }

    func testARoomNameStaysOnePathSegment() {
        XCTAssertEqual(
            ChatEmbedAddress.url(port: 11004, room: "dm/a b")?.absoluteString,
            "http://localhost:11004/embed/r/dm%2Fa%20b"
        )
    }

    func testTheThemeIsCarriedInTheAddress() throws {
        let url = try XCTUnwrap(ChatEmbedAddress.url(port: 11004, room: "a"))
        XCTAssertEqual(ChatEmbedAddress.themed(url, isDark: true).query, "theme=dark")
        XCTAssertEqual(ChatEmbedAddress.themed(url, isDark: false).query, "theme=light")
    }
}
