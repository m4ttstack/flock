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

    func testAnUnlinkedBackgroundChatShowsOnEveryTab() {
        let selection = ChatSidebarSelection(chat: chat("a", pane: "bg:w1:p1"), isEnded: false)
        XCTAssertTrue(selection.isLinked(toTab: ["w2:p3"]))
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

    func testAStartedAgentAnswersWithItsPane() {
        let reply = Data(#"{"agent":{"paneId":"bg:w1:p2"}}"#.utf8)
        XCTAssertEqual(ChatSlackAgent.pane(stdout: reply, exitCode: 0), "bg:w1:p2")
        XCTAssertNil(ChatSlackAgent.pane(stdout: reply, exitCode: 1))
        XCTAssertNil(ChatSlackAgent.pane(stdout: Data("{}".utf8), exitCode: 0))
    }

    func testTheAgentStartsInTheBackgroundInTheRepo() {
        XCTAssertEqual(
            ChatSlackAgent.startArguments(repo: "/src/acme"),
            ["agent", "start", "--bg", "--repo", "/src/acme", "--label", "slack-support", "--json"]
        )
    }

    private func peek(_ lines: [String]) throws -> Data {
        try JSONEncoder().encode(["lines": lines])
    }

    func testARefusalIsReadOffTheAgentsScreen() throws {
        let screen = try peek(["noise", "The Slack chat did not open: already in a", "   chat with them", "", "after"])
        XCTAssertEqual(ChatSlackAgent.refusal(stdout: screen, exitCode: 0), "already in a chat with them")
    }

    func testTheLastRefusalOnScreenIsTheOneThatCounts() throws {
        let screen = try peek(["The Slack chat did not open: old", "", "The Slack chat did not open: new"])
        XCTAssertEqual(ChatSlackAgent.refusal(stdout: screen, exitCode: 0), "new")
    }

    func testAScreenWithNoRefusalSaysNothing() throws {
        XCTAssertNil(ChatSlackAgent.refusal(stdout: try peek(["working"]), exitCode: 0))
        XCTAssertNil(ChatSlackAgent.refusal(stdout: Data(), exitCode: 1))
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
