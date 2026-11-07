import FlockCore
import Foundation
import XCTest

/// Answers each `.status` with the next scripted `slackChat`, the last
/// repeating; nil is `"slackChat":null`, and `SlackScript.lookupFailed` leaves
/// the key out. Records every verb it is handed.
private actor SlackScript: ChatRunning {
    static let lookupFailed = "<lookup failed>"

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
            let key = chat == Self.lookupFailed ? "" : #","slackChat":\#(slack)"#
            let json = #"{"handle":"kay","name":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[]\#(key)}"#
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

/// Answers each liveness check with the next reading, the last repeating.
private final class GoneScript: @unchecked Sendable {
    private var readings: [Bool]

    init(_ readings: [Bool]) { self.readings = readings }

    func next() -> Bool { readings.count > 1 ? readings.removeFirst() : readings[0] }
}

private actor SendLog {
    private(set) var lines: [(pane: String, line: String)] = []

    func record(pane: String, line: String) {
        lines.append((pane, line))
    }
}

private actor StartLog {
    private(set) var repos: [String] = []

    func record(_ repo: String) {
        repos.append(repo)
    }
}

@MainActor
final class ChatStoreSlackTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")

    private func makeStore(
        _ script: SlackScript, agent: String? = "bg:w9:p1", refusal: String? = nil, screen: String? = nil,
        sends: SendLog = SendLog(), starts: StartLog = StartLog(), defaults: UserDefaults? = nil,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, gone: [Bool] = [false]
    ) async -> (ChatStore, ToastCenter) {
        let toasts = ToastCenter()
        let suite = defaults ?? UserDefaults(suiteName: "ChatStoreSlackTests.\(UUID().uuidString)")!
        let store = ChatStore(
            toasts: toasts, probe: { "/bin/echo" }, rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in script }, pause: { _ in },
            typeIntoPane: { pane, line in
                await sends.record(pane: pane, line: line)
                return nil
            },
            startAgent: { repo in
                await starts.record(repo)
                return agent
            },
            typeIntoAgent: { pane, line in
                await sends.record(pane: pane, line: line)
                return refusal
            },
            readAgentRefusal: { _ in screen },
            agentIsGone: { [script = GoneScript(gone)] _ in script.next() },
            now: now,
            defaults: suite
        )
        await store.probeTask.value
        await store.peekTask?.value
        return (store, toasts)
    }

    private let repo = ChatSlackRepo(path: "/src/acme")

    private func open(_ name: String = "alex") -> ChatSidebarChat {
        ChatSidebarChat(room: "dm", pane: "bg:w9:p1", name: name)
    }

    /// The exit runs in a task of its own, with nothing to await.
    private func exitLines(_ sends: SendLog) async -> [String] {
        for _ in 0..<200 {
            let lines = await sends.lines.map(\.line).filter { $0 == ChatSlackAgent.exitLine }
            if !lines.isEmpty { return lines }
            await Task.yield()
        }
        return []
    }

    func testStartTypesTheCommandIntoABackgroundAgentInTheRepo() async {
        let sends = SendLog()
        let starts = StartLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), sends: sends, starts: starts)

        let started = await store.startSlackChat(pane, person: "O'Brien", problem: "line one\nline two", repo: repo)

        XCTAssertTrue(started)
        let repos = await starts.repos
        XCTAssertEqual(repos, ["/src/acme"])
        let lines = await sends.lines
        XCTAssertEqual(lines.map(\.pane), ["bg:w9:p1"])
        XCTAssertEqual(lines.map(\.line), ["/slack-support O'Brien line one line two"])
    }

    func testAStartedChatReadsAsOpeningUntilRtListsIt() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]))

        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        XCTAssertEqual(store.slackRow(for: pane), .opening, "a line that was taken proves nothing yet")

        await store.noteSlackChats([open()])
        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNil(toasts.current)
    }

    func testAnAgentThatWouldNotStartSaysSoAndTypesNothing() async {
        let sends = SendLog()
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), agent: nil, sends: sends)

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        XCTAssertFalse(started)
        XCTAssertNil(store.slackTransition(for: pane))
        let lines = await sends.lines
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(toasts.current?.message, "Slack chat not started: no agent")
    }

    func testARefusedLineExitsTheAgentAndSaysWhy() async {
        let sends = SendLog()
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), refusal: "at a prompt", sends: sends)

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        XCTAssertFalse(started)
        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
        XCTAssertEqual(toasts.current?.message, "Slack chat not started: at a prompt")
        let exits = await exitLines(sends)
        XCTAssertEqual(exits, [ChatSlackAgent.exitLine])
    }

    func testABlankFormStartsNoAgent() async {
        let starts = StartLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), starts: starts)

        let started = await store.startSlackChat(pane, person: " ", problem: "hi", repo: repo)

        XCTAssertFalse(started)
        let repos = await starts.repos
        XCTAssertTrue(repos.isEmpty)
    }

    func testAStoreWithNoChatStartsNoAgent() async {
        let starts = StartLog()
        let store = ChatStore(
            toasts: ToastCenter(), probe: { nil }, rtProbe: { true }, deckProbe: { true },
            startAgent: { repo in
                await starts.record(repo)
                return nil
            },
            defaults: UserDefaults(suiteName: "ChatStoreSlackTests.\(UUID().uuidString)")!
        )
        await store.probeTask.value

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        XCTAssertFalse(started)
        let repos = await starts.repos
        XCTAssertTrue(repos.isEmpty)
    }

    func testARefusalOnTheAgentsScreenEndsTheStartAndSaysWhy() async {
        let sends = SendLog()
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), screen: "already in a chat", sends: sends)
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        await store.noteSlackChats([])

        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertEqual(toasts.current?.message, "Slack chat not started: already in a chat")
        let exits = await exitLines(sends)
        XCTAssertEqual(exits, [ChatSlackAgent.exitLine])
    }

    func testAnAgentStillStartingIsLeftAlone() async {
        let sends = SendLog()
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), sends: sends)
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        await store.noteSlackChats([])

        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
        XCTAssertNil(toasts.current)
    }

    func testAChatThatOpensLateKeepsItsOwner() async {
        let sends = SendLog()
        var clock = ContinuousClock.now
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), sends: sends, now: { clock })
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        clock = clock.advanced(by: ChatSlackAgent.openDeadline + .seconds(1))
        await store.noteSlackChats([])
        await store.noteSlackChats([])

        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
        XCTAssertEqual(toasts.current?.message, "Slack chat didn't open")
        if let id = toasts.current?.id { toasts.dismiss(id) }
        await store.noteSlackChats([])
        XCTAssertNil(toasts.current)

        await store.noteSlackChats([open()])

        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
        let exits = await exitLines(sends)
        XCTAssertTrue(exits.isEmpty)
    }

    /// Times the chat out, then runs one tick per reading.
    private func tickThroughGone(_ readings: [Bool], sends: SendLog = SendLog()) async -> ChatStore {
        var clock = ContinuousClock.now
        let (store, _) = await makeStore(SlackScript(chats: [nil]), sends: sends, now: { clock }, gone: readings)
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        clock = clock.advanced(by: ChatSlackAgent.openDeadline + .seconds(1))
        await store.noteSlackChats([])
        for _ in readings { await store.noteSlackChats([]) }
        return store
    }

    func testOneMissKeepsATimedOutChat() async {
        let store = await tickThroughGone([true])
        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
    }

    func testTwoConsecutiveMissesRetireWithoutExit() async {
        let sends = SendLog()
        let store = await tickThroughGone([true, true], sends: sends)

        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
        XCTAssertNil(store.slackTransition(for: pane))
        let exits = await exitLines(sends)
        XCTAssertTrue(exits.isEmpty)
    }

    func testAMissThenPresentThenMissKeepsTheChat() async {
        let store = await tickThroughGone([true, false, true])
        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
    }

    func testATimedOutChatWhoseAgentPaneLivesIsKept() async {
        let store = await tickThroughGone([false, false])
        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
    }

    func testARefusedChatStillRetires() async {
        let sends = SendLog()
        var clock = ContinuousClock.now
        let (store, _) = await makeStore(
            SlackScript(chats: [nil]), screen: "already in a chat", sends: sends, now: { clock })
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        clock = clock.advanced(by: ChatSlackAgent.openDeadline + .seconds(1))

        await store.noteSlackChats([])

        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
        let exits = await exitLines(sends)
        XCTAssertEqual(exits, [ChatSlackAgent.exitLine])
    }

    func testAChatThatClosedExitsItsAgent() async {
        let sends = SendLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), sends: sends)
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        await store.noteSlackChats([open()])

        await store.noteSlackChats([])

        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
        let exits = await exitLines(sends)
        XCTAssertEqual(exits, [ChatSlackAgent.exitLine])
    }

    func testEndClosesTheAgentsChatFromThePaneThatStartedIt() async {
        let script = SlackScript(chats: [nil])
        let (store, _) = await makeStore(script)
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        await store.endSlackChat(pane)

        let verbs = await script.verbs
        XCTAssertTrue(verbs.contains(.slackClose(pane: "bg:w9:p1")))
    }

    func testAnAgentsChatThatOutlivesTheCloseWindowOffersEndAgain() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]))
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        await store.noteSlackChats([open()])

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
        XCTAssertEqual(toasts.current?.message, "Slack chat still open. Check the pane")
    }

    func testAFailedCloseOnAnAgentsChatLeavesNoWait() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil], closeError: "no chat"))
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        await store.endSlackChat(pane)

        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNil(store.slackWatch(for: pane))
    }

    func testTheLinkToAnAgentSurvivesARelaunch() async {
        let defaults = UserDefaults(suiteName: "ChatStoreSlackTests.\(UUID().uuidString)")!
        let (first, _) = await makeStore(SlackScript(chats: [nil]), defaults: defaults)
        _ = await first.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        let (second, _) = await makeStore(SlackScript(chats: [nil]), defaults: defaults)

        XCTAssertEqual(second.slackOwner(ofAgent: "bg:w9:p1"), pane)
        XCTAssertEqual(second.slackRepoName(ofAgent: "bg:w9:p1"), "acme")
    }

    func testAnAgentsChatDoesNotBlockSignOut() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil]))
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        await store.noteSlackChats([open()])

        XCTAssertFalse(store.signOutIsBlocked(for: pane))
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

    /// `status` leaves `slackChat` out when rt can't answer, which says nothing
    /// about the chat, so only a real null ends the wait.
    func testAFailedLookupMidCloseKeepsWaiting() async {
        let script = SlackScript(chats: ["alex", SlackScript.lookupFailed, "alex", nil])
        let (store, _) = await makeStore(script)
        await store.refreshStatus(for: pane)

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        let verbs = await script.verbs
        XCTAssertEqual(verbs.filter { $0 == .status(pane: "w1:p1") }.count, 4, "the watch read past the failed lookup")
        XCTAssertEqual(store.status(for: pane)?.slack, .noChat)
    }

    func testAFailedLookupWithNoKnownChatStillKeepsTheCloseWaiting() async {
        let script = SlackScript(chats: [SlackScript.lookupFailed, SlackScript.lookupFailed, nil])
        let (store, _) = await makeStore(script)

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        let verbs = await script.verbs
        XCTAssertEqual(verbs.filter { $0 == .status(pane: "w1:p1") }.count, 3)
        XCTAssertEqual(store.status(for: pane)?.slack, .noChat)
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

    func testAFailedLookupDoesNotLiftTheSignOutBlock() async {
        let script = SlackScript(chats: ["alex", SlackScript.lookupFailed])
        let (store, toasts) = await makeStore(script)
        await store.refreshStatus(for: pane)

        await store.signOut(pane)

        let verbs = await script.verbs
        XCTAssertFalse(verbs.contains(.signOut(pane: "w1:p1")))
        XCTAssertEqual(store.status(for: pane)?.slack, .open(name: "alex"))
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
        let (store, toasts) = await makeStore(SlackScript(chats: ["alex"]))
        await store.refreshStatus(for: pane)

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        XCTAssertEqual(
            ChatSlackRow.resolve(status: store.status(for: pane), transition: store.slackTransition(for: pane)), .open(name: "alex")
        )
        XCTAssertEqual(toasts.current?.message, "Slack chat still open. Check the pane")
    }
}
