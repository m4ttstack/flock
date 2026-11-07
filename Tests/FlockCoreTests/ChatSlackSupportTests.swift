import XCTest
@testable import FlockCore

final class ChatSlackSupportTests: XCTestCase {
    // MARK: - The form

    func testAFormNeedsAPersonAndAProblem() {
        XCTAssertTrue(ChatSlackStart.canStart(person: "U0TEST", problem: "the deck will not load"))
        XCTAssertTrue(ChatSlackStart.canStart(person: "O'Brien", problem: "line one\nline two"))
        XCTAssertFalse(ChatSlackStart.canStart(person: "  \n", problem: "hi"))
        XCTAssertFalse(ChatSlackStart.canStart(person: "alex", problem: " \n "))
        XCTAssertFalse(ChatSlackStart.canStart(person: "", problem: ""))
    }

    // MARK: - The send

    func testTheSendNamesThePaneAndAsksForJSON() {
        XCTAssertEqual(
            ChatSlackCommand.sendArguments(pane: "w1:p2", line: "/slack-support alex hi"),
            ["pane", "send", "w1:p2", "--text", "/slack-support alex hi", "--json"]
        )
    }

    /// The daemon refuses this text from anything that identifies as a pane,
    /// and Flock started from a herdr shell inherits that shell's pane id.
    func testTheSendCarriesNoPaneIdentity() {
        let environment = ChatSlackCommand.sendEnvironment(["HERDR_PANE_ID": "w1:p9", "PATH": "/opt/bin", "RT_BATCH": "1"])
        XCTAssertNil(environment["HERDR_PANE_ID"])
        XCTAssertEqual(environment, ["PATH": "/opt/bin", "RT_BATCH": "1"])
    }

    func testOnlyRefusedIsARefusal() {
        for delivered in ["accepted", "queued"] {
            let reply = Data(#"{"ok":true,"paneId":"w1:p2","delivered":"\#(delivered)"}"#.utf8)
            XCTAssertNil(ChatSlackCommand.refusal(stdout: reply, exitCode: 0), delivered)
        }
    }

    func testARefusalCarriesItsReason() {
        let reply = Data(#"{"ok":true,"paneId":"w1:p2","delivered":"refused","reason":"at a prompt"}"#.utf8)
        XCTAssertEqual(ChatSlackCommand.refusal(stdout: reply, exitCode: 0), "at a prompt")
    }

    func testARefusalWithNoReasonStillRefuses() {
        let reply = Data(#"{"ok":true,"paneId":"w1:p2","delivered":"refused"}"#.utf8)
        XCTAssertEqual(ChatSlackCommand.refusal(stdout: reply, exitCode: 0), "the pane refused it")
    }

    /// A failed or unreadable answer says nothing about whether the text was
    /// typed, so only `slackChat` can settle it.
    func testAnUnreadableAnswerIsNotARefusal() {
        XCTAssertNil(ChatSlackCommand.refusal(stdout: Data("nope".utf8), exitCode: 0))
        XCTAssertNil(ChatSlackCommand.refusal(stdout: Data(#"{"error":"herdr timed out"}"#.utf8), exitCode: 1))
    }

    // MARK: - The row

    private func status(signedIn: Bool = true, slack: ChatSlackState) -> ChatStatus {
        ChatStatus(handle: "kay", state: "live", pane: "w1:p1", signedIn: signedIn, rooms: [], slack: slack)
    }

    /// No key is a lookup that failed, so a known chat outlives it.
    func testAMissingKeyKeepsAKnownChat() {
        let merged = status(slack: .unsupported).keepingSlackChat(from: status(slack: .open(name: "alex")))
        XCTAssertEqual(merged.slack, .open(name: "alex"))
    }

    func testANullReplacesAKnownChat() {
        let merged = status(slack: .noChat).keepingSlackChat(from: status(slack: .open(name: "alex")))
        XCTAssertEqual(merged.slack, .noChat)
    }

    func testAMissingKeyStaysUnsupportedWithNoKnownChat() {
        XCTAssertEqual(status(slack: .unsupported).keepingSlackChat(from: nil).slack, .unsupported)
        XCTAssertEqual(status(slack: .unsupported).keepingSlackChat(from: status(slack: .noChat)).slack, .unsupported)
    }

    /// rt ties a chat to the agent holding it, so a new agent in the same pane
    /// must not inherit one.
    func testAMissingKeyDropsAChatHeldByAnotherAgent() {
        let incoming = ChatStatus(handle: "remy", state: "live", pane: "w1:p1", signedIn: true, rooms: [], slack: .unsupported)
        XCTAssertEqual(incoming.keepingSlackChat(from: status(slack: .open(name: "alex"))).slack, .unsupported)
    }

    func testASignedOutPaneDropsAKnownChat() {
        let merged = status(signedIn: false, slack: .unsupported).keepingSlackChat(from: status(slack: .open(name: "alex")))
        XCTAssertEqual(merged.slack, .unsupported)
    }

    func testAnOldHerdrChatHidesTheRow() {
        XCTAssertNil(ChatSlackRow.resolve(status: status(slack: .unsupported), transition: nil))
    }

    func testAnOldHerdrChatHidesTheRowEvenMidTransition() {
        XCTAssertNil(ChatSlackRow.resolve(status: status(slack: .unsupported), transition: .opening))
    }

    func testAPaneNotSignedInHidesTheRow() {
        XCTAssertNil(ChatSlackRow.resolve(status: status(signedIn: false, slack: .noChat), transition: nil))
    }

    func testAPaneWithNoStatusYetHidesTheRow() {
        XCTAssertNil(ChatSlackRow.resolve(status: nil, transition: nil))
    }

    func testASignedInPaneWithNoChatOffersOn() {
        XCTAssertEqual(ChatSlackRow.resolve(status: status(slack: .noChat), transition: nil), .available)
    }

    func testTheRowShowsWhoThePaneIsTalkingTo() {
        XCTAssertEqual(
            ChatSlackRow.resolve(status: status(slack: .open(name: "alex")), transition: nil), .open(name: "alex")
        )
    }

    /// `opening` is only a wait: nothing but `slackChat` says the chat exists.
    func testOpeningNeverReadsAsOpenWithoutSlackChat() {
        XCTAssertEqual(ChatSlackRow.resolve(status: status(slack: .noChat), transition: .opening), .opening)
    }

    func testSlackChatBeatsAnOpeningStillRunning() {
        XCTAssertEqual(
            ChatSlackRow.resolve(status: status(slack: .open(name: "alex")), transition: .opening), .open(name: "alex")
        )
    }

    func testAClosingChatKeepsItsName() {
        XCTAssertEqual(
            ChatSlackRow.resolve(status: status(slack: .open(name: "alex")), transition: .closing), .closing(name: "alex")
        )
    }

    func testAChatThatEndedOffersOnAgainMidClose() {
        XCTAssertEqual(ChatSlackRow.resolve(status: status(slack: .noChat), transition: .closing), .available)
    }

    // MARK: - Sign out

    /// A sign-out drops the chat with no goodbye, so it waits for End chat.
    func testAnOpenOrClosingChatBlocksSignOut() {
        XCTAssertTrue(ChatSlackRow.open(name: "alex").blocksSignOut)
        XCTAssertTrue(ChatSlackRow.closing(name: "alex").blocksSignOut)
    }

    func testNoChatLeavesSignOutAlone() {
        XCTAssertFalse(ChatSlackRow.available.blocksSignOut)
        XCTAssertFalse(ChatSlackRow.opening.blocksSignOut)
    }

    // MARK: - The people search

    private let people = [
        ChatSlackPerson(name: "Alex Example", person: "U1", title: "Support lead"),
        ChatSlackPerson(name: "Alex Example", person: "U2", title: "Sales"),
        ChatSlackPerson(name: "Alexis Sample", person: "U3", title: nil),
        ChatSlackPerson(name: "Sal Tester", person: "U4", title: nil),
        ChatSlackPerson(name: "Kim Lee", person: "U5", title: "Palace guard")
    ]

    func testAnEmptyQueryShowsNoOne() {
        XCTAssertEqual(ChatSlackPeopleSearch.matches("  ", in: people), [])
    }

    func testAQueryIgnoresCase() {
        XCTAssertEqual(ChatSlackPeopleSearch.matches("KIM", in: people).map(\.person), ["U5"])
    }

    func testAWordStartRanksAheadOfAMatchInsideAWord() {
        XCTAssertEqual(ChatSlackPeopleSearch.matches("al", in: people).map(\.person), ["U1", "U2", "U3", "U4"])
        XCTAssertEqual(ChatSlackPeopleSearch.matches("le", in: people).map(\.person), ["U5", "U1", "U2", "U3"])
    }

    func testATitleIsNotSearched() {
        XCTAssertEqual(ChatSlackPeopleSearch.matches("palace", in: people), [])
    }

    func testResultsStopAtTheLimit() {
        let crowd = (0..<9).map { ChatSlackPerson(name: "Alex \($0)", person: "U\($0)", title: nil) }
        XCTAssertEqual(ChatSlackPeopleSearch.matches("alex", in: crowd).count, ChatSlackPeopleSearch.limit)
    }

    func testATitleShowsOnlyWhenTwoResultsShareAName() {
        let results = ChatSlackPeopleSearch.matches("al", in: people)
        XCTAssertEqual(ChatSlackPeopleSearch.titleToShow(for: results[0], among: results), "Support lead")
        let unique = ChatSlackPeopleSearch.matches("kim", in: people)
        XCTAssertNil(ChatSlackPeopleSearch.titleToShow(for: unique[0], among: unique))
    }

    // MARK: - The Person box

    private var alex: ChatSlackPerson { people[0] }

    func testPickingFillsTheBoxWithTheName() {
        var entry = ChatSlackPersonEntry()
        entry.type("al")
        entry.pick(alex)
        XCTAssertEqual(entry.query, "Alex Example")
        XCTAssertEqual(entry.picked, alex)
    }

    /// AppKit writes a text field's value back when it loses focus, which is
    /// exactly what happens as a pick moves focus to Problem.
    func testTheSameTextWrittenBackKeepsThePick() {
        var entry = ChatSlackPersonEntry()
        entry.pick(alex)
        entry.type("Alex Example")
        XCTAssertEqual(entry.picked, alex)
    }

    func testEditingThePickedNameClearsThePick() {
        var entry = ChatSlackPersonEntry()
        entry.pick(alex)
        entry.type("Alex Exampl")
        XCTAssertNil(entry.picked)
    }

    func testTypingResetsTheHighlight() {
        var entry = ChatSlackPersonEntry()
        entry.type("al")
        entry.moveHighlight(by: 1, among: 4)
        entry.type("ale")
        XCTAssertEqual(entry.highlighted, 0)
    }

    func testTheHighlightWrapsBothWays() {
        var entry = ChatSlackPersonEntry()
        entry.moveHighlight(by: -1, among: 3)
        XCTAssertEqual(entry.highlighted, 2)
        entry.moveHighlight(by: 1, among: 3)
        XCTAssertEqual(entry.highlighted, 0)
    }
}
