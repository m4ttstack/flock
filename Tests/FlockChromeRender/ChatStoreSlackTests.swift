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

private actor SendLog {
    private(set) var lines: [(pane: String, line: String)] = []

    func record(pane: String, line: String) {
        lines.append((pane, line))
    }
}

private struct StartCall: Equatable {
    let person: String
    let brief: String
    let pane: String
    let repo: String
}

private actor StartLog {
    private(set) var calls: [StartCall] = []
    private(set) var resumed: [Int] = []

    func record(_ call: StartCall) {
        calls.append(call)
    }

    func recordResume(_ conversation: Int) {
        resumed.append(conversation)
    }
}

@MainActor
final class ChatStoreSlackTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")

    private func makeStore(
        _ script: SlackScript, started: ChatSlackOutcome = .done, resumed: ChatSlackOutcome = .done,
        sends: SendLog = SendLog(), starts: StartLog = StartLog(), defaults: UserDefaults? = nil,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
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
            startSlack: { person, brief, pane, repo in
                await starts.record(StartCall(person: person, brief: brief, pane: pane, repo: repo))
                return started
            },
            resumeSlack: { conversation in
                await starts.recordResume(conversation)
                return resumed
            },
            now: now,
            defaults: suite
        )
        await store.probeTask.value
        await store.peekTask?.value
        return (store, toasts)
    }

    private let repo = ChatSlackRepo(path: "/src/acme")

    /// A chat rt lists as started from `requester`, held by a background agent.
    private func open(_ name: String = "alex", requester: String? = "w1:p1", id: Int = 4) -> ChatSidebarChat {
        ChatSidebarChat(room: "dm", pane: "bg:w9:p1", name: name, requesterPane: requester, id: id)
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

    private func savedLegacyAgents(_ json: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ChatStoreSlackTests.\(UUID().uuidString)")!
        defaults.set(Data(json.utf8), forKey: "chat.slackAgents")
        return defaults
    }

    private let legacyAgent = #"{"w1:p1":{"pane":"bg:w9:p1","repoName":"acme","name":"alex"}}"#

    func testStartRunsSlackStartWithTheProblemAndTypesNothingIntoAnyPane() async {
        let sends = SendLog()
        let starts = StartLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), sends: sends, starts: starts)

        let started = await store.startSlackChat(pane, person: "U0TEST", problem: "line one\nline two", repo: repo)

        XCTAssertTrue(started)
        let calls = await starts.calls
        XCTAssertEqual(calls, [StartCall(person: "U0TEST", brief: "line one\nline two", pane: "w1:p1", repo: "/src/acme")])
        let lines = await sends.lines
        XCTAssertTrue(lines.isEmpty)
    }

    func testAStartedChatReadsAsOpeningUntilRtListsIt() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]))

        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        XCTAssertEqual(store.slackRow(for: pane), .opening)

        await store.noteSlackChats([open()])
        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
        XCTAssertNil(toasts.current)
    }

    func testAChatListedForAnotherPaneIsNotThisPanes() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil]))

        await store.noteSlackChats([open(requester: "w2:p2")])

        XCTAssertNotEqual(store.slackRow(for: pane), .open(name: "alex"))
        XCTAssertEqual(store.slackRow(for: PaneID(rawValue: "w2:p2")), .open(name: "alex"))
    }

    func testARefusedStartSaysWhyAndLeavesNoOpeningRow() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), started: .failed("Already in a chat with them"))

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        XCTAssertFalse(started)
        XCTAssertNotEqual(store.slackRow(for: pane), .opening)
        XCTAssertEqual(toasts.current?.message, "Slack chat not started: Already in a chat with them")
    }

    func testABlankFormStartsNothing() async {
        let starts = StartLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), starts: starts)

        let blankPerson = await store.startSlackChat(pane, person: " ", problem: "hi", repo: repo)
        let blankProblem = await store.startSlackChat(pane, person: "alex", problem: " \n ", repo: repo)

        XCTAssertFalse(blankPerson)
        XCTAssertFalse(blankProblem)
        let calls = await starts.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAStoreWithNoChatStartsNothing() async {
        let starts = StartLog()
        let store = ChatStore(
            toasts: ToastCenter(), probe: { nil }, rtProbe: { true }, deckProbe: { true },
            startSlack: { person, brief, pane, repo in
                await starts.record(StartCall(person: person, brief: brief, pane: pane, repo: repo))
                return .done
            },
            defaults: UserDefaults(suiteName: "ChatStoreSlackTests.\(UUID().uuidString)")!
        )
        await store.probeTask.value

        let started = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        XCTAssertFalse(started)
        let calls = await starts.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAChatThatNeverOpensSaysSoOnceAndStopsWaiting() async {
        var clock = ContinuousClock.now
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), now: { clock })
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)

        await store.noteSlackChats([])
        XCTAssertEqual(store.slackRow(for: pane), .opening)
        XCTAssertNil(toasts.current)

        clock = clock.advanced(by: ChatSlackAgent.openDeadline + .seconds(1))
        await store.noteSlackChats([])

        XCTAssertNotEqual(store.slackRow(for: pane), .opening)
        XCTAssertEqual(toasts.current?.message, "Slack chat didn't open")
    }

    func testAChatThatOpensLateStillShowsOnItsPane() async {
        var clock = ContinuousClock.now
        let (store, _) = await makeStore(SlackScript(chats: [nil]), now: { clock })
        _ = await store.startSlackChat(pane, person: "alex", problem: "hi", repo: repo)
        clock = clock.advanced(by: ChatSlackAgent.openDeadline + .seconds(1))
        await store.noteSlackChats([])

        await store.noteSlackChats([open()])

        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
    }

    func testTheRequesterOwnsTheAgentPaneItsChatRunsOn() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil]))

        await store.noteSlackChats([open()])

        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p2"))
    }

    func testEndClosesTheChatByItsAgentPaneFromEitherPane() async {
        let script = SlackScript(chats: [nil])
        let (store, _) = await makeStore(script)
        await store.noteSlackChats([open()])

        await store.endSlackChat(pane)
        await store.endSlackChat(PaneID(rawValue: "bg:w9:p1"))

        let verbs = await script.verbs
        XCTAssertEqual(verbs.filter { $0 == .slackClose(pane: "bg:w9:p1") }.count, 2)
    }

    func testAClosingChatReadsAsClosingUntilRtStopsListingIt() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil]))
        await store.noteSlackChats([open()])

        await store.endSlackChat(pane)
        XCTAssertEqual(store.slackRow(for: pane), .closing(name: "alex"))
        XCTAssertEqual(store.slackTransition(for: PaneID(rawValue: "bg:w9:p1")), .closing)

        await store.noteSlackChats([])
        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNotEqual(store.slackRow(for: pane), .closing(name: "alex"))
    }

    func testAChatThatOutlivesTheCloseWindowOffersEndAgain() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]))
        await store.noteSlackChats([open()])

        await store.endSlackChat(pane)
        await store.slackWatch(for: pane)?.value

        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
        XCTAssertEqual(toasts.current?.message, "Slack chat still open. Check the pane")
    }

    func testAFailedCloseLeavesNoWait() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil], closeError: "no chat"))
        await store.noteSlackChats([open()])

        await store.endSlackChat(pane)

        XCTAssertNil(store.slackTransition(for: pane))
        XCTAssertNil(store.slackWatch(for: pane))
    }

    func testARequestedChatDoesNotBlockSignOut() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil]))
        await store.noteSlackChats([open()])

        XCTAssertFalse(store.signOutIsBlocked(for: pane))
    }

    func testResumeRunsSlackResumeForTheClosedChat() async {
        let starts = StartLog()
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), starts: starts)

        let resumed = await store.resumeSlackChat(7)

        XCTAssertTrue(resumed)
        let ids = await starts.resumed
        XCTAssertEqual(ids, [7])
        XCTAssertNil(toasts.current)
    }

    func testAResumeRtRefusesSaysWhy() async {
        let (store, toasts) = await makeStore(SlackScript(chats: [nil]), resumed: .failed("That chat is still open"))

        let resumed = await store.resumeSlackChat(7)

        XCTAssertFalse(resumed)
        XCTAssertEqual(toasts.current?.message, "Slack chat not resumed: That chat is still open")
    }

    func testAnOldLinkToAnAgentIsStillRead() async {
        let (store, _) = await makeStore(SlackScript(chats: [nil]), defaults: savedLegacyAgents(legacyAgent))

        XCTAssertEqual(store.slackOwner(ofAgent: "bg:w9:p1"), pane)
        XCTAssertEqual(store.slackRepoName(ofAgent: "bg:w9:p1"), "acme")
        await store.noteSlackChats([open(requester: nil)])
        XCTAssertEqual(store.slackRow(for: pane), .open(name: "alex"))
    }

    func testAnOldLinkToAnAgentThatNeverOpenedIsDropped() async {
        let defaults = savedLegacyAgents(#"{"w1:p1":{"pane":"bg:w9:p1","repoName":"acme"}}"#)
        let (store, _) = await makeStore(SlackScript(chats: [nil]), defaults: defaults)

        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
    }

    func testAnOldLinkEndsWithItsChatAndExitsItsAgent() async {
        let sends = SendLog()
        let (store, _) = await makeStore(SlackScript(chats: [nil]), sends: sends, defaults: savedLegacyAgents(legacyAgent))
        await store.noteSlackChats([open(requester: nil)])

        await store.noteSlackChats([])

        XCTAssertNil(store.slackOwner(ofAgent: "bg:w9:p1"))
        let exits = await exitLines(sends)
        XCTAssertEqual(exits, [ChatSlackAgent.exitLine])
    }

    func testAnOldLinksChatClosesThroughItsAgentPane() async {
        let script = SlackScript(chats: [nil])
        let (store, _) = await makeStore(script, defaults: savedLegacyAgents(legacyAgent))

        await store.endSlackChat(pane)

        let verbs = await script.verbs
        XCTAssertTrue(verbs.contains(.slackClose(pane: "bg:w9:p1")))
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
