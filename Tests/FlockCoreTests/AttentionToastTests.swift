import XCTest
@testable import FlockCore

private actor FocusRecordingClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        return Data("{}".utf8)
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// One workspace the user is looking at (`w1`, focused pane `w1:p1`) and one
/// they are not (`w2`, four panes in tab `w2:t1`). Every pane is `idle` unless
/// `statuses` says otherwise.
private func attentionModel(focusedPane: String = "w1:p1", statuses: [String: AgentStatus] = [:]) -> SessionModel {
    func status(_ pane: String) -> String { (statuses[pane] ?? .idle).rawValue }
    let panes = [("w2:p1", "migration"), ("w2:p2", "runner"), ("w2:p3", "docs"), ("w2:p4", "bridge")]
        .map { id, label in
            #"{"pane_id":"\#(id)","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"\#(status(id))","revision":0,"cwd":"/tmp","label":"\#(label)"}"#
        }
        .joined(separator: ",")
    let json = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"\#(focusedPane)",
     "workspaces":[{"workspace_id":"w1","label":"flock","number":1,"active_tab_id":"w1:t1","agent_status":"idle"},
                   {"workspace_id":"w2","label":"repo-tools","number":2,"active_tab_id":"w2:t1","agent_status":"idle"}],
     "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"main","number":1,"pane_count":1,"agent_status":"idle"},
             {"tab_id":"w2:t1","workspace_id":"w2","label":"agents","number":1,"pane_count":4,"agent_status":"idle"}],
     "panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"\#(status("w1:p1"))","revision":0,"cwd":"/tmp","label":"shell"},\#(panes)],
     "layouts":[]}
    """#
    return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
}

@MainActor
private func makeViewModel(_ client: any HerdrCommandClient, clock: TestClock) -> SessionViewModel {
    SessionViewModel(client: client, now: { clock.now })
}

final class AttentionToastTests: XCTestCase {
    // MARK: - which transitions speak

    func testOnlyBlockedAndFinishedTransitionsRaiseAnything() {
        XCTAssertEqual(AttentionToastStack.kind(from: .working, to: .blocked), .needsInput)
        XCTAssertEqual(AttentionToastStack.kind(from: .idle, to: .blocked), .needsInput)
        XCTAssertEqual(AttentionToastStack.kind(from: .working, to: .idle), .finished)
        XCTAssertEqual(AttentionToastStack.kind(from: .working, to: .done), .finished)

        XCTAssertNil(AttentionToastStack.kind(from: .idle, to: .working))
        XCTAssertNil(AttentionToastStack.kind(from: .blocked, to: .idle))
        XCTAssertNil(AttentionToastStack.kind(from: .unknown, to: .idle))
        XCTAssertNil(AttentionToastStack.kind(from: .blocked, to: .blocked))
    }

    // MARK: - raising

    @MainActor
    func testABlockedTransitionOnAnUnfocusedPaneRaisesAToast() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)

        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)

        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 1)
        let toast = try? XCTUnwrap(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:p1")))
        XCTAssertEqual(toast?.kind, .needsInput)
        XCTAssertEqual(toast?.headline, "migration needs input")
        XCTAssertEqual(toast?.breadcrumb, "repo-tools › agents")
    }

    /// You are already looking at it.
    @MainActor
    func testTheSameTransitionOnTheFocusedPaneRaisesNothing() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(focusedPane: "w2:p1"), connection: .live)

        viewModel.update(model: attentionModel(focusedPane: "w2:p1", statuses: ["w2:p1": .blocked]), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// The first snapshot of a session describes a state, not a change. A
    /// window that opened onto three blocked agents must not shout three
    /// times about agents that were already waiting.
    @MainActor
    func testTheFirstSnapshotOfASessionRaisesNothing() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)

        viewModel.update(
            model: attentionModel(statuses: ["w2:p1": .blocked, "w2:p2": .blocked]), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    @MainActor
    func testAFinishedRunRaisesTheAutoDismissingToast() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)

        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done]), connection: .live)

        XCTAssertEqual(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:p1"))?.kind, .finished)
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:p1"))?.headline, "migration finished")
    }

    // MARK: - coalescing

    @MainActor
    func testTwoFlapsWithinTheCoalescingWindowStayOneToast() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)
        let firstRaise = viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:p1"))?.raisedAt

        clock.advance(1)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)

        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 1)
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:p1"))?.raisedAt, firstRaise)
    }

    /// A flap must not hand a finished toast another six seconds every time
    /// the agent twitches, nor re-sort the stack under a pointer already on
    /// it. Outside the window it is a new thing to say, and does both.
    func testCoalescingKeepsTheClockAndRenewalRestartsIt() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var stack = AttentionToastStack()
        stack.raise(toast(pane: "w2:p1", kind: .finished, at: start))
        stack.raise(toast(pane: "w2:p2", kind: .finished, at: start))

        XCTAssertEqual(stack.raise(toast(pane: "w2:p1", kind: .needsInput, at: start.addingTimeInterval(1.9))), .coalesced)
        XCTAssertEqual(stack.toast(pane: PaneID(rawValue: "w2:p1"))?.raisedAt, start)
        XCTAssertEqual(stack.toast(pane: PaneID(rawValue: "w2:p1"))?.kind, .needsInput)
        XCTAssertEqual(stack.toasts.first?.paneID, PaneID(rawValue: "w2:p2"), "a flap does not re-sort the stack")

        XCTAssertEqual(stack.raise(toast(pane: "w2:p1", kind: .finished, at: start.addingTimeInterval(2.0))), .renewed)
        XCTAssertEqual(stack.toast(pane: PaneID(rawValue: "w2:p1"))?.raisedAt, start.addingTimeInterval(2.0))
        XCTAssertEqual(stack.toasts.first?.paneID, PaneID(rawValue: "w2:p1"))
    }

    // MARK: - depth

    @MainActor
    func testAFourthToastCollapsesTheStackToThreeAndAPill() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)

        var statuses: [String: AgentStatus] = [:]
        for pane in ["w2:p1", "w2:p2", "w2:p3", "w2:p4"] {
            statuses[pane] = .blocked
            clock.advance(10)
            viewModel.update(model: attentionModel(statuses: statuses), connection: .live)
        }

        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 4)
        XCTAssertEqual(viewModel.attentionToasts.visible.count, 3)
        XCTAssertEqual(viewModel.attentionToasts.collapsedCount, 1)
        XCTAssertEqual(viewModel.attentionToasts.visible.first?.paneID, PaneID(rawValue: "w2:p4"), "newest first")
    }

    // MARK: - lifetime

    @MainActor
    func testAFinishedToastExpiresAndANeedsInputToastDoesNot() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done, "w2:p2": .blocked]), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 2)

        clock.advance(5.9)
        viewModel.sweepAttentionToasts()
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 2)

        clock.advance(0.1)
        viewModel.sweepAttentionToasts()

        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p2")])
    }

    // MARK: - withdrawal

    @MainActor
    func testANeedsInputToastIsWithdrawnOnceThePaneIsNoLongerBlocked() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)
        XCTAssertFalse(viewModel.attentionToasts.isEmpty)

        clock.advance(10)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// The snapshot that reports a pane calming down usually arrives INSIDE
    /// the coalescing window (Matt answers in the herdr TUI a second after
    /// the toast went up), and inside the window that reads as a flap, so the
    /// toast is kept. Nothing else re-examines it when the grace expires: if
    /// the sweep does not, a question that was answered in a second stays on
    /// screen until an unrelated event or the resnapshot moves the model.
    @MainActor
    func testANeedsInputToastIsWithdrawnWhenTheGraceExpiresWithNoFurtherEvents() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)

        clock.advance(1.5)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        XCTAssertFalse(viewModel.attentionToasts.isEmpty, "inside the window this is a flap, not an answer")

        clock.advance(0.6)
        viewModel.sweepAttentionToasts()

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    @MainActor
    func testAToastIsWithdrawnOnceItsPaneIsTheFocusedOne() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)
        XCTAssertFalse(viewModel.attentionToasts.isEmpty)

        viewModel.update(model: attentionModel(focusedPane: "w2:p1", statuses: ["w2:p1": .blocked]), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// Clicking a toast for a pane herdr has since closed would focus
    /// nothing, so a toast never outlives the pane it points at.
    @MainActor
    func testAToastIsWithdrawnOnceHerdrStopsReportingItsPane() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)

        var without = attentionModel(statuses: ["w2:p1": .blocked])
        without.panes.removeValue(forKey: PaneID(rawValue: "w2:p1"))
        viewModel.update(model: without, connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    @MainActor
    func testClearingDropsEveryToastAndDismissingDropsOne() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked, "w2:p2": .blocked]), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 2)

        viewModel.dismissAttentionToast(pane: PaneID(rawValue: "w2:p1"))
        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p2")])

        viewModel.clearAttentionToasts()
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    // MARK: - the jump

    @MainActor
    func testClickingAToastFocusesItsWorkspaceTabAndPaneByExplicitID() async throws {
        let clock = TestClock()
        let client = FocusRecordingClient()
        let viewModel = makeViewModel(client, clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)

        await viewModel.jumpToAttentionToast(pane: PaneID(rawValue: "w2:p1"))

        let calls = await client.calls
        XCTAssertEqual(calls.map(\.method), ["workspace.focus", "tab.focus", "pane.focus"])
        XCTAssertEqual(calls.map { $0.params.values.compactMap(stringValue).first }, ["w2", "w2:t1", "w2:p1"])
        XCTAssertTrue(viewModel.attentionToasts.isEmpty, "the toast goes as the jump takes it")
    }

    @MainActor
    func testJumpingToAToastThatIsNoLongerUpSendsNothing() async {
        let clock = TestClock()
        let client = FocusRecordingClient()
        let viewModel = makeViewModel(client, clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)

        await viewModel.jumpToAttentionToast(pane: PaneID(rawValue: "w2:p1"))

        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

private func toast(pane: String, kind: AttentionToast.Kind, at date: Date) -> AttentionToast {
    AttentionToast(
        paneID: PaneID(rawValue: pane), tabID: TabID(rawValue: "w2:t1"), workspaceID: WorkspaceID(rawValue: "w2"),
        kind: kind, headline: pane, breadcrumb: "repo-tools › agents", raisedAt: date
    )
}

private func stringValue(_ value: JSONValue) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
}
