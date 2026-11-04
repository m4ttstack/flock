import FlockCore
import Foundation
import XCTest

/// Answers each `.status` with the next scripted `slackChat`, the last
/// repeating; nil is `"slackChat":null`. Records every verb it is handed.
private actor SlackScript: ChatRunning {
    private var chats: [String?]
    private let closeError: String?
    private let people: String?
    private(set) var verbs: [ChatVerb] = []

    init(chats: [String?], closeError: String? = nil, people: String? = nil) {
        self.chats = chats
        self.closeError = closeError
        self.people = people
    }

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        verbs.append(verb)
        switch verb {
        case .peek:
            return (Data(#"{"buddies":[],"rooms":[]}"#.utf8), 0)
        case .status:
            let chat = chats.count > 1 ? chats.removeFirst() : chats[0]
            let slack = chat.map { #"{"name":"\#($0)","openedAt":1700}"# } ?? "null"
            let json = #"{"handle":"kay","name":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[],"slackChat":\#(slack)}"#
            return (Data(json.utf8), 0)
        case .slackClose:
            if let closeError { return (Data(#"{"error":"\#(closeError)"}"#.utf8), 1) }
            return (Data(#"{"ok":true,"conversationId":4,"closed":false}"#.utf8), 0)
        case .signOut:
            return (Data(#"{"handle":null,"state":"not signed in","pane":null,"signedIn":false,"rooms":[],"slackChat":null}"#.utf8), 0)
        case .slackPeople:
            guard let people else { return (Data(#"{"error":"unknown verb"}"#.utf8), 1) }
            return (Data(people.utf8), 0)
        default:
            throw ChatFailure(message: "SlackScript has no answer for \(verb)")
        }
    }
}

private actor SendLog {
    private(set) var lines: [(pane: String, line: String)] = []

    func record(pane: String, line: String) {
        lines.append((pane, line))
    }
}

@MainActor
final class ChatStoreSlackTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")

    private func makeStore(_ script: SlackScript, refusal: String? = nil, sends: SendLog = SendLog()) async -> (ChatStore, ToastCenter) {
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts, probe: { "/bin/echo" }, rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in script }, pause: { _ in },
            typeIntoPane: { pane, line in
                await sends.record(pane: pane, line: line)
                return refusal
            }
        )
        await store.probeTask.value
        await store.peekTask?.value
        return (store, toasts)
    }

    func testOnTypesTheCommandIntoThePane() async {
        let sends = SendLog()
        let (store, _) = await makeStore(SlackScript(chats: ["alex"]), sends: sends)

        let started = await store.startSlackChat(pane, person: "O'Brien", problem: "line one\nline two")

        XCTAssertTrue(started)
        let lines = await sends.lines
        XCTAssertEqual(lines.map(\.pane), ["w1:p1"])
        XCTAssertEqual(lines.map(\.line), ["/slack-support O'Brien line one line two"])
    }

    func testOnShowsItWorkedFromSlackChatNotTheSendResult() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil, nil, "alex"]))

        _ = await store.startSlackChat(pane, person: "alex", problem: "hi")
        XCTAssertEqual(store.slackTransition(for: pane), .opening, "a send that was taken proves nothing yet")
        await store.slackWatch(for: pane)?.value

        XCTAssertEqual(store.status(for: pane)?.slack, .open(name: "alex"))
        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNil(toasts.current)
    }

    func testASendThatWasTakenButOpenedNothingDoesNotReadAsOpen() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]))

        _ = await store.startSlackChat(pane, person: "alex", problem: "hi")
        await store.slackWatch(for: pane)?.value

        XCTAssertEqual(ChatSlackRow.resolve(status: store.status(for: pane), transition: store.slackTransition(for: pane)), .available)
        XCTAssertEqual(toasts.current?.message, "No Slack chat yet. Check the pane")
    }

    func testARefusalStopsThereAndSaysWhy() async {
        let script = SlackScript(chats: [nil])
        let (store, toasts) = await makeStore(script, refusal: "at a prompt")

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi")

        XCTAssertFalse(started)
        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNil(store.slackWatch(for: pane))
        XCTAssertEqual(toasts.current?.message, "Slack chat not started: at a prompt")
    }

    func testABlankFormTypesNothing() async {
        let sends = SendLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), sends: sends)

        let started = await store.startSlackChat(pane, person: " ", problem: "hi")

        XCTAssertFalse(started)
        let lines = await sends.lines
        XCTAssertTrue(lines.isEmpty)
    }

    func testAStoreWithNoChatTypesNothing() async {
        let sends = SendLog()
        let store = ChatStore(
            toasts: ToastCenter(), probe: { nil }, rtProbe: { true }, deckProbe: { true },
            typeIntoPane: { pane, line in
                await sends.record(pane: pane, line: line)
                return nil
            }
        )
        await store.probeTask.value

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi")

        XCTAssertFalse(started)
        let lines = await sends.lines
        XCTAssertTrue(lines.isEmpty)
    }

    func testOffRunsTheCloseVerbForThePane() async {
        let script = SlackScript(chats: [nil])
        let (store, _) = await makeStore(script)

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        let verbs = await script.verbs
        XCTAssertTrue(verbs.contains(.slackClose(pane: "w1:p1")))
    }

    /// A close by pane always answers `closed: false`: the pane says goodbye
    /// first, so the chat stays listed for a while.
    func testOffStaysClosingUntilSlackChatClears() async {
        let (store, _) = await makeStore(SlackScript(chats: ["alex", "alex", "alex", nil]))
        await store.refreshStatus(for: pane)

        await store.endSlackChat(pane)
        XCTAssertEqual(store.slackTransition(for: pane), .closing)
        await store.slackWatch(for: pane)?.value

        XCTAssertEqual(store.status(for: pane)?.slack, .noChat)
        XCTAssertNil(store.slackTransition(for: pane))
    }

    func testAFailedOffKeepsTheChatAndSaysWhy() async {
        let (store, toasts) = await makeStore(SlackScript(chats: ["alex"], closeError: "No Slack chat is open in w1:p1"))
        await store.refreshStatus(for: pane)

        await store.endSlackChat(pane)

        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertEqual(store.status(for: pane)?.slack, .open(name: "alex"))
        XCTAssertEqual(toasts.current?.message, "No Slack chat is open in w1:p1")
    }

    /// The menu reads a cached status, so sign-out asks again before it acts:
    /// a chat started by hand in the pane would not be in that cache.
    func testSignOutIsRefusedWhileAChatIsOpen() async {
        let script = SlackScript(chats: ["alex"])
        let (store, toasts) = await makeStore(script)

        await store.signOut(pane)

        let verbs = await script.verbs
        XCTAssertFalse(verbs.contains(.signOut(pane: "w1:p1")))
        XCTAssertEqual(toasts.current?.message, "End the Slack chat first")
    }

    func testSignOutGoesThroughWithNoChatOpen() async {
        let script = SlackScript(chats: [nil])
        let (store, toasts) = await makeStore(script)

        await store.signOut(pane)

        let verbs = await script.verbs
        XCTAssertTrue(verbs.contains(.signOut(pane: "w1:p1")))
        XCTAssertNil(toasts.current)
    }

    func testAnUnavailableListReadsAsNoPeople() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil], people: #"{"ok":false,"reason":"unavailable","error":"no token"}"#))

        let people = await store.slackPeople()

        XCTAssertNil(people)
        XCTAssertNil(toasts.current, "the form falls back to free text with no toast")
    }

    func testAFailedListSaysNothing() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]))

        let people = await store.slackPeople()

        XCTAssertNil(people)
        XCTAssertNil(toasts.current)
    }

    func testTheListComesBackInOrder() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil], people: #"{"ok":true,"people":[{"name":"Alex Example","person":"U0TEST"}]}"#))

        let people = await store.slackPeople()

        XCTAssertEqual(people?.map(\.person), ["U0TEST"])
    }

    func testAChatThatOutlivesTheCloseWindowOffersOffAgain() async {
        let (store, _) = await makeStore(SlackScript(chats: ["alex"]))
        await store.refreshStatus(for: pane)

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        XCTAssertEqual(
            ChatSlackRow.resolve(status: store.status(for: pane), transition: store.slackTransition(for: pane)), .open(name: "alex")
        )
    }
}
