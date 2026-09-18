import FlockCore
import Foundation
import XCTest

/// Queues one scripted result per call, in order, and records the verbs it
/// was asked to run -- an actor so it is `Sendable` without a lock, since
/// `ChatRunning` crosses from the store's `@MainActor` to wherever a test
/// awaits it.
private actor FakeChatRunning: ChatRunning {
    private(set) var calls: [ChatVerb] = []
    private var queuedResults: [Result<(stdout: Data, exitCode: Int32), Error>]

    init(_ queuedResults: [Result<(stdout: Data, exitCode: Int32), Error>] = []) {
        self.queuedResults = queuedResults
    }

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        calls.append(verb)
        guard !queuedResults.isEmpty else {
            throw ChatFailure(message: "FakeChatRunning has no queued result for \(verb)")
        }
        return try queuedResults.removeFirst().get()
    }

    func recordedCalls() -> [ChatVerb] { calls }
}

/// Lets a test resolve two in-flight calls in whichever order it chooses,
/// independent of the order they reached the runner -- what proves a stale
/// reply cannot win a race against a newer one.
private actor OrderedChatRunning: ChatRunning {
    private var arrivalCount = 0
    private var resultContinuations: [CheckedContinuation<(stdout: Data, exitCode: Int32), Error>] = []
    private var arrivalWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        let index = arrivalCount
        arrivalCount += 1
        arrivalWaiters.removeValue(forKey: index)?.resume()
        return try await withCheckedThrowingContinuation { resultContinuations.append($0) }
    }

    /// Suspends until the call at `index` (0-based, arrival order) has
    /// reached `run`, so a test can prove two calls are both in flight
    /// before resolving either.
    func waitForArrival(of index: Int) async {
        if arrivalCount > index { return }
        await withCheckedContinuation { arrivalWaiters[index] = $0 }
    }

    func resolve(_ index: Int, _ result: Result<(stdout: Data, exitCode: Int32), Error>) {
        guard resultContinuations.indices.contains(index) else { return }
        switch result {
        case let .success(value): resultContinuations[index].resume(returning: value)
        case let .failure(error): resultContinuations[index].resume(throwing: error)
        }
    }
}

private func ok(_ json: String) -> Result<(stdout: Data, exitCode: Int32), Error> {
    .success((stdout: Data(json.utf8), exitCode: 0))
}

private func failed(_ json: String) -> Result<(stdout: Data, exitCode: Int32), Error> {
    .success((stdout: Data(json.utf8), exitCode: 1))
}

@MainActor
final class ChatStoreTests: XCTestCase {
    private static let pane = PaneID(rawValue: "w1:p1")
    private static let statusJSON = #"""
    {"handle":"@matt","state":"active","pane":"w1:p1","signedIn":true,"rooms":["#general"]}
    """#
    private static let signedOutStatusJSON = #"""
    {"handle":"@matt","state":"inactive","pane":"w1:p1","signedIn":false,"rooms":[]}
    """#
    /// `ChatStatus`'s memberwise init is not public across the module
    /// boundary; decoding the same JSON the fake hands the store is what a
    /// caller outside `FlockCore` has to do instead.
    private static let expectedStatus = try! JSONDecoder().decode(ChatStatus.self, from: Data(statusJSON.utf8))

    /// Awaits `probeTask` before handing the store back: every test but the
    /// one proving the pre-answer state wants a settled `isAvailable`, not a
    /// race against the store's own background probe.
    private func makeStore(
        results: [Result<(stdout: Data, exitCode: Int32), Error>] = [], available: Bool = true
    ) async -> (ChatStore, FakeChatRunning, ToastCenter) {
        let runner = FakeChatRunning(results)
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts, probe: { available ? "/bin/echo" : nil }, makeRunner: { _ in runner }
        )
        await store.probeTask.value
        return (store, runner, toasts)
    }

    // MARK: - status caches per pane

    func testASuccessfulStatusCaches() async {
        let (store, runner, toasts) = await makeStore(results: [ok(Self.statusJSON)])

        await store.refreshStatus(for: Self.pane)

        XCTAssertEqual(store.status(for: Self.pane), Self.expectedStatus)
        XCTAssertNil(toasts.current)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [.status(pane: "w1:p1")])
    }

    /// The cache holds whatever the last successful call put there; a later
    /// failure must not clear it out from under a view already showing it.
    func testAFailureRaisesAToastAndLeavesTheCacheAlone() async {
        let (store, _, toasts) = await makeStore(
            results: [ok(Self.statusJSON), failed(#"{"error":"chat daemon unreachable"}"#)]
        )

        await store.refreshStatus(for: Self.pane)
        await store.refreshStatus(for: Self.pane)

        XCTAssertEqual(store.status(for: Self.pane), Self.expectedStatus)
        XCTAssertEqual(toasts.current?.message, "chat daemon unreachable")
        XCTAssertEqual(toasts.current?.kind, .info)
    }

    /// A raw `CancellationError` is what happens when a popover's `.task` is
    /// torn down mid-call; it must pass through silently, never as a toast.
    func testCancellationNeverBecomesAToast() async {
        let (store, _, toasts) = await makeStore(results: [ok(Self.statusJSON), .failure(CancellationError())])

        await store.refreshStatus(for: Self.pane)
        await store.refreshStatus(for: Self.pane)

        XCTAssertEqual(store.status(for: Self.pane), Self.expectedStatus)
        XCTAssertNil(toasts.current)
    }

    // MARK: - isAvailable gates every verb

    func testIsAvailableIsFalseWhenTheProbeResolvesToNoBinary() async {
        let (store, runner, toasts) = await makeStore(results: [ok(Self.statusJSON)], available: false)

        XCTAssertFalse(store.isAvailable)
        let peeked = await store.peek()
        await store.refreshStatus(for: Self.pane)

        XCTAssertNil(peeked)
        XCTAssertNil(store.status(for: Self.pane))
        XCTAssertNil(toasts.current, "absence is not a failure and must not toast")
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.isEmpty, "no verb may run while chat is unavailable")
    }

    func testIsAvailableIsTrueOnceTheProbeResolvesABinary() async {
        let (store, _, _) = await makeStore()
        XCTAssertTrue(store.isAvailable)
    }

    /// Availability is false until the probe answers, not only once it
    /// answers "no binary": a store read during launch, before the
    /// background probe has resolved at all, must still run no verbs.
    func testNoVerbRunsAndIsAvailableStaysFalseBeforeTheProbeAnswers() async {
        let runner = FakeChatRunning([ok(Self.statusJSON)])
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts,
            probe: { await withCheckedContinuation { (_: CheckedContinuation<String?, Never>) in } },
            makeRunner: { _ in runner }
        )

        XCTAssertFalse(store.isAvailable)
        let peeked = await store.peek()
        await store.refreshStatus(for: Self.pane)

        XCTAssertNil(peeked)
        XCTAssertNil(store.status(for: Self.pane))
        XCTAssertNil(toasts.current)
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.isEmpty, "no verb may run before the probe has answered")
    }

    // MARK: - sign in/out land the same status object as a refresh

    func testSignInCachesTheReturnedStatus() async {
        let (store, runner, _) = await makeStore(results: [ok(Self.statusJSON)])

        await store.signIn(Self.pane)

        XCTAssertEqual(store.status(for: Self.pane), Self.expectedStatus)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [.signIn(pane: "w1:p1")])
    }

    // MARK: - a stale, out-of-order reply never overwrites a newer one

    /// A `refreshStatus` already in flight when a `signIn` completes must not
    /// then land its own, older answer over the top of the fresher one --
    /// resolved deliberately out of order to prove the generation guard, not
    /// call order, decides what wins.
    func testAStaleResponseNeverOverwritesANewerOneForTheSamePane() async {
        let runner = OrderedChatRunning()
        let toasts = ToastCenter()
        let store = ChatStore(toasts: toasts, probe: { "/bin/echo" }, makeRunner: { _ in runner })
        await store.probeTask.value

        let older = Task { await store.refreshStatus(for: Self.pane) }
        await runner.waitForArrival(of: 0)
        let newer = Task { await store.signIn(Self.pane) }
        await runner.waitForArrival(of: 1)

        await runner.resolve(1, ok(Self.statusJSON))
        await newer.value
        await runner.resolve(0, ok(Self.signedOutStatusJSON))
        await older.value

        XCTAssertEqual(store.status(for: Self.pane)?.signedIn, true)
    }

    // MARK: - quick send never branches on `ok`; only a thrown failure counts

    func testQuickSendSucceedsOnAnyDecodableReply() async {
        let (store, runner, toasts) = await makeStore(results: [ok(#"{"to":"@matt"}"#)])

        let sent = await store.quickSend(to: "@matt", body: "hey")

        XCTAssertTrue(sent)
        XCTAssertNil(toasts.current)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [.quickSend(to: "@matt", body: "hey")])
    }

    func testQuickSendFailsAndToastsOnAThrownFailure() async {
        let (store, _, toasts) = await makeStore(results: [failed(#"{"error":"not signed in"}"#)])

        let sent = await store.quickSend(to: "@matt", body: "hey")

        XCTAssertFalse(sent)
        XCTAssertEqual(toasts.current?.message, "not signed in")
    }

    // MARK: - broadcast passes its result through untouched

    /// Only `refused` is a failure, and deciding what that means for a toast
    /// is the broadcast view's job (`ChatBroadcastSummary`), not the store's:
    /// the store must hand back exactly what rt said, refusals included,
    /// without collapsing a partial refusal into a call failure.
    func testBroadcastReturnsAPartialRefusalRatherThanToastingOrNilling() async {
        let json = #"""
        {"ok":false,"results":[{"paneId":"w1:p1","ok":false,"delivered":"refused","error":"not signed in"}]}
        """#
        let (store, _, toasts) = await makeStore(results: [ok(json)])

        let broadcast = await store.broadcast(panes: ["w1:p1"], body: "pausing")

        XCTAssertEqual(broadcast?.ok, false)
        XCTAssertEqual(broadcast?.results.first?.delivered, "refused")
        XCTAssertNil(toasts.current)
    }

    // MARK: - viewer URL

    func testViewerURLDecodesTheReturnedURL() async {
        let (store, _, _) = await makeStore(results: [ok(#"{"url":"https://chat.example/r/general"}"#)])

        let url = await store.viewerURL(room: "general")

        XCTAssertEqual(url, URL(string: "https://chat.example/r/general"))
    }
}
