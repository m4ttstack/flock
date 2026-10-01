import FlockCore
import Foundation
import XCTest

/// Answers each `.peek` with the next scripted list, the last repeating; a
/// nil entry fails that peek. Every other verb fails.
private actor PeekScript: ChatRunning {
    private var answers: [[(handle: String, pane: String)]?]
    private(set) var runs = 0

    init(_ answers: [[(handle: String, pane: String)]?]) {
        self.answers = answers
    }

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        runs += 1
        guard case .peek = verb else { throw ChatFailure(message: "PeekScript only peeks") }
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        guard let answer else { throw ChatFailure(message: "chat daemon unreachable") }
        let buddies = answer.map {
            #"{"handle":"\#($0.handle)","paneId":"\#($0.pane)","status":"online","unread":0,"mentions":0}"#
        }
        return (Data(#"{"buddies":[\#(buddies.joined(separator: ","))],"rooms":[]}"#.utf8), 0)
    }
}

@MainActor
final class ChatStoreBuddiesTests: XCTestCase {
    private func makeStore(_ script: PeekScript) async -> (ChatStore, ToastCenter) {
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts, probe: { "/bin/echo" }, rtProbe: { true }, deckProbe: { true }, makeRunner: { _ in script }
        )
        await store.probeTask.value
        await store.peekTask?.value
        return (store, toasts)
    }

    func testTheLaunchPeekRecordsWhoIsSignedInByPane() async {
        let (store, _) = await makeStore(PeekScript([[("@ivy", "w1:p1"), ("@oak", "w1:p4")]]))
        XCTAssertEqual(store.buddies[PaneID(rawValue: "w1:p1")]?.handle, "@ivy")
        XCTAssertEqual(store.buddies[PaneID(rawValue: "w1:p4")]?.handle, "@oak")
    }

    func testARefreshDropsWhoeverSignedOut() async {
        let (store, _) = await makeStore(PeekScript([[("@ivy", "w1:p1"), ("@oak", "w1:p4")], [("@ivy", "w1:p1")]]))
        await store.refreshBuddies()
        XCTAssertEqual(Set(store.buddies.keys), [PaneID(rawValue: "w1:p1")])
    }

    /// A machine without rt has no chat: the switcher's refresh spawns
    /// nothing, says nothing, and leaves nobody to show.
    func testWithoutRtNothingIsAskedAndNobodyIsShown() async {
        let script = PeekScript([[("@ivy", "w1:p1")]])
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts, probe: { "/bin/echo" }, rtProbe: { false }, deckProbe: { true }, makeRunner: { _ in script }
        )
        await store.probeTask.value
        await store.peekTask?.value

        await store.refreshBuddies()

        XCTAssertFalse(store.isAvailable)
        XCTAssertTrue(store.buddies.isEmpty)
        let runs = await script.runs
        XCTAssertEqual(runs, 0)
        XCTAssertNil(toasts.current)
    }

    func testAFailedRefreshKeepsTheLastListAndSaysNothing() async {
        let (store, toasts) = await makeStore(PeekScript([[("@ivy", "w1:p1")], nil]))
        await store.refreshBuddies()
        XCTAssertEqual(store.buddies[PaneID(rawValue: "w1:p1")]?.handle, "@ivy")
        XCTAssertNil(toasts.current, "a switcher refresh fails quietly")
    }
}
