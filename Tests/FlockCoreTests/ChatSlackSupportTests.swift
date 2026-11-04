import XCTest
@testable import FlockCore

final class ChatSlackSupportTests: XCTestCase {
    // MARK: - The typed line

    func testALineCarriesThePersonAndTheProblem() {
        XCTAssertEqual(
            ChatSlackCommand.line(person: "alex", problem: "the deck will not load"),
            "/slack-support alex the deck will not load"
        )
    }

    func testAPersonWithASpaceIsDoubleQuoted() {
        XCTAssertEqual(ChatSlackCommand.line(person: "Alex Example", problem: "hi"), #"/slack-support "Alex Example" hi"#)
    }

    /// The command's parser takes a bare leading `'` for an open quote.
    func testAPersonStartingWithAnApostropheIsDoubleQuoted() {
        XCTAssertEqual(ChatSlackCommand.line(person: "'t Hooft", problem: "hi"), #"/slack-support "'t Hooft" hi"#)
        XCTAssertEqual(ChatSlackCommand.line(person: "'Neil", problem: "hi"), #"/slack-support "'Neil" hi"#)
    }

    func testAnApostropheInsideANameGoesThroughIntact() {
        XCTAssertEqual(ChatSlackCommand.line(person: "O'Brien", problem: "hi"), "/slack-support O'Brien hi")
    }

    /// A `"` inside the person would end the quoted name early.
    func testDoubleQuotesAreStrippedFromThePerson() {
        XCTAssertEqual(ChatSlackCommand.line(person: #"Alex "Al" Example"#, problem: "hi"), #"/slack-support "Alex Al Example" hi"#)
        XCTAssertEqual(ChatSlackCommand.line(person: #""alex""#, problem: "hi"), "/slack-support alex hi")
    }

    func testNewlinesInTheProblemCollapseToSpaces() {
        XCTAssertEqual(
            ChatSlackCommand.line(person: "alex", problem: "line one\nline two\r\n\n  line three\n"),
            "/slack-support alex line one line two line three"
        )
    }

    func testANewlineInThePersonCollapsesToo() {
        XCTAssertEqual(ChatSlackCommand.line(person: "  Alex\nExample ", problem: "hi"), #"/slack-support "Alex Example" hi"#)
    }

    func testDoubleQuotesInTheProblemAreLeftAlone() {
        XCTAssertEqual(ChatSlackCommand.line(person: "alex", problem: #"it says "nope""#), #"/slack-support alex it says "nope""#)
    }

    func testABlankPersonOrProblemMakesNoLine() {
        XCTAssertNil(ChatSlackCommand.line(person: "  \n", problem: "hi"))
        XCTAssertNil(ChatSlackCommand.line(person: #""""#, problem: "hi"))
        XCTAssertNil(ChatSlackCommand.line(person: "alex", problem: " \n "))
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

    /// A picked person is typed by id, which is one bare word.
    func testAnIdGoesIntoTheLineBare() {
        XCTAssertEqual(ChatSlackCommand.line(person: "U0TEST", problem: "hi"), "/slack-support U0TEST hi")
    }
}
