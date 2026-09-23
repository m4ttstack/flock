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
private func attentionModel(
    focusedPane: String = "w1:p1",
    statuses: [String: AgentStatus] = [:],
    secondWorkspaceLabel: String = "repo-tools"
) -> SessionModel {
    func status(_ pane: String) -> String { (statuses[pane] ?? .idle).rawValue }
    let panes = [("w2:p1", "migration"), ("w2:p2", "runner"), ("w2:p3", "docs"), ("w2:p4", "bridge")]
        .map { id, label in
            #"{"pane_id":"\#(id)","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"\#(status(id))","revision":0,"cwd":"/tmp","label":"\#(label)"}"#
        }
        .joined(separator: ",")
    let json = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"\#(focusedPane)",
     "workspaces":[{"workspace_id":"w1","label":"flock","number":1,"active_tab_id":"w1:t1","agent_status":"idle"},
                   {"workspace_id":"w2","label":"\#(secondWorkspaceLabel)","number":2,"active_tab_id":"w2:t1","agent_status":"idle"}],
     "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"main","number":1,"pane_count":1,"agent_status":"idle"},
             {"tab_id":"w2:t1","workspace_id":"w2","label":"agents","number":1,"pane_count":4,"agent_status":"idle"}],
     "panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"\#(status("w1:p1"))","revision":0,"cwd":"/tmp","label":"shell"},\#(panes)],
     "layouts":[]}
    """#
    return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
}

@MainActor
private func makeViewModel(
    _ client: any HerdrCommandClient, clock: TestClock, lifetime: NotificationLifetime = .untilSeen
) -> SessionViewModel {
    SessionViewModel(client: client, now: { clock.now }, notificationLifetime: { lifetime })
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
        XCTAssertEqual(toast?.subject, "migration")
        XCTAssertEqual(toast?.kind.label, "Needs input")
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
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:p1"))?.kind.label, "Finished")
    }

    // MARK: - herds

    /// A herd is a batch run somebody else is already watching, so its panes
    /// have no toast to give: the pane never gets one raised, and the stack
    /// never learns a count it would then show in the "more" pill.
    @MainActor
    func testABlockedTransitionInAHerdWorkspaceRaisesNothing() {
        let herd = "herd: docs-sweep-20260922-112541"
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(secondWorkspaceLabel: herd), connection: .live)

        viewModel.update(
            model: attentionModel(statuses: ["w2:p1": .blocked], secondWorkspaceLabel: herd), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
        XCTAssertEqual(viewModel.attentionToasts.collapsedCount(limit: AttentionToastStack.minimumVisible), 0)
    }

    @MainActor
    func testAFinishedTransitionInAHerdWorkspaceRaisesNothing() {
        let herd = "herd: docs-sweep-20260922-112541"
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(
            model: attentionModel(statuses: ["w2:p1": .working], secondWorkspaceLabel: herd), connection: .live)

        viewModel.update(
            model: attentionModel(statuses: ["w2:p1": .done], secondWorkspaceLabel: herd), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// The workspace a pane sits in is not fixed for the pane's life: a herd
    /// reuses a workspace that already carries its label, and a pane can be
    /// moved into one. A toast raised before that is a claim that has stopped
    /// holding, so it goes the same way the other withdrawals go.
    @MainActor
    func testAToastIsWithdrawnOnceItsPaneTurnsOutToBeHerdRun() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)
        XCTAssertFalse(viewModel.attentionToasts.isEmpty)

        viewModel.update(
            model: attentionModel(
                statuses: ["w2:p1": .blocked], secondWorkspaceLabel: "herd: docs-sweep-20260922-112541"),
            connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// The shepherd itself is hand-driven, and it runs in an ordinary
    /// workspace rather than the herd's own, so nothing about a herd being on
    /// screen may quieten the rest of the window.
    @MainActor
    func testPanesOutsideTheHerdWorkspaceStillToastWhileAHerdIsRunning() {
        let herd = "herd: docs-sweep-20260922-112541"
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(
            model: attentionModel(focusedPane: "w2:p4", secondWorkspaceLabel: herd), connection: .live)

        viewModel.update(
            model: attentionModel(
                focusedPane: "w2:p4", statuses: ["w1:p1": .blocked, "w2:p1": .blocked],
                secondWorkspaceLabel: herd),
            connection: .live)

        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w1:p1")])
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
        XCTAssertEqual(viewModel.attentionToasts.visible(limit: AttentionToastStack.minimumVisible).count, 3)
        XCTAssertEqual(viewModel.attentionToasts.collapsedCount(limit: AttentionToastStack.minimumVisible), 1)
        XCTAssertEqual(viewModel.attentionToasts.visible(limit: AttentionToastStack.minimumVisible).first?.paneID, PaneID(rawValue: "w2:p4"), "newest first")
    }

    // MARK: - lifetime

    @MainActor
    func testAFinishedToastExpiresAndANeedsInputToastDoesNot() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock, lifetime: .fiveSeconds)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done, "w2:p2": .blocked]), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 2)

        clock.advance(4.9)
        viewModel.sweepAttentionToasts()
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 2)

        clock.advance(0.1)
        viewModel.sweepAttentionToasts()

        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p2")])
    }

    @MainActor
    func testUntilSeenKeepsAFinishedToastUntilItsPaneIsSeen() {
        let clock = TestClock()
        let viewModel = SessionViewModel(
            client: FocusRecordingClient(), now: { clock.now }, notificationLifetime: { .untilSeen }
        )
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done]), connection: .live)

        clock.advance(3600)
        viewModel.sweepAttentionToasts()

        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p1")])
    }

    /// Never raises nothing, and choosing it clears what is already up at
    /// the dock's next sweep.
    @MainActor
    func testNeverRaisesNothingAndClearsWhatIsUp() {
        let clock = TestClock()
        var lifetime = NotificationLifetime.fiveSeconds
        let viewModel = SessionViewModel(client: FocusRecordingClient(), now: { clock.now }, notificationLifetime: { lifetime })
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done, "w2:p2": .blocked]), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 2)

        lifetime = .never
        viewModel.sweepAttentionToasts()
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)

        clock.advance(10)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working, "w2:p2": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done, "w2:p2": .blocked]), connection: .live)
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    @MainActor
    func testNotificationLifetimeDefaultsToUntilSeenAndPersists() throws {
        let suite = "dev.mattstack.flock.notification-lifetime-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = NotificationLifetimeStore(userDefaults: defaults)
        XCTAssertEqual(store.active, .untilSeen)
        store.select(.fiveSeconds)
        XCTAssertEqual(NotificationLifetimeStore(userDefaults: defaults).active, .fiveSeconds)
        XCTAssertEqual(NotificationLifetime.fiveSeconds.finishedLifetime, 5)
        XCTAssertNil(NotificationLifetime.untilSeen.finishedLifetime)
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
    func testAFinishedToastIsWithdrawnOnceItsPaneIsSeen() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done]), connection: .live)
        XCTAssertFalse(viewModel.attentionToasts.isEmpty)

        viewModel.update(model: attentionModel(focusedPane: "w2:p1", statuses: ["w2:p1": .done]), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// A look is not an answer: the question stays until herdr stops
    /// reporting the pane as blocked.
    @MainActor
    func testANeedsInputToastOutlivesAVisitAndGoesWhenAnswered() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .blocked]), connection: .live)

        clock.advance(10)
        viewModel.update(model: attentionModel(focusedPane: "w2:p1", statuses: ["w2:p1": .blocked]), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p1")])

        viewModel.update(model: attentionModel(focusedPane: "w1:p1", statuses: ["w2:p1": .working]), connection: .live)
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// herdr moves a finished agent from `done` to `idle` once someone looks
    /// at the pane, in flock or in herdr's own TUI; that clears the card too.
    @MainActor
    func testAFinishedToastGoesWhenHerdrClearsDone() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done]), connection: .live)

        clock.advance(10)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .idle]), connection: .live)

        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// An agent that went straight from working to idle has no `done` for
    /// herdr to clear, so its card waits for the pane to be seen instead of
    /// going at once.
    @MainActor
    func testAFinishedToastRaisedAtIdleWaitsToBeSeen() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .idle]), connection: .live)

        clock.advance(3600)
        viewModel.sweepAttentionToasts()
        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p1")])

        viewModel.update(model: attentionModel(focusedPane: "w2:p1", statuses: ["w2:p1": .idle]), connection: .live)
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    /// A status that bounces off and back inside the coalescing window is a
    /// flap, not the claim clearing.
    @MainActor
    func testAFlapInsideTheWindowKeepsTheCard() {
        let clock = TestClock()
        let viewModel = makeViewModel(FocusRecordingClient(), clock: clock)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .working]), connection: .live)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .done]), connection: .live)

        clock.advance(1)
        viewModel.update(model: attentionModel(statuses: ["w2:p1": .idle]), connection: .live)

        XCTAssertEqual(viewModel.attentionToasts.toasts.map(\.paneID), [PaneID(rawValue: "w2:p1")])
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

    /// The keyboard route takes the bottom card on screen, and never one
    /// counted under the pill: that toast is not displayed.
    @MainActor
    func testOpeningTheOldestTakesTheBottomCardDrawnNotOneUnderThePill() async {
        let clock = TestClock()
        let client = FocusRecordingClient()
        let viewModel = makeViewModel(client, clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)
        var statuses: [String: AgentStatus] = [:]
        for pane in ["w2:p1", "w2:p2", "w2:p3", "w2:p4"] {
            statuses[pane] = .blocked
            clock.advance(10)
            viewModel.update(model: attentionModel(statuses: statuses), connection: .live)
        }
        viewModel.attentionCardLimit = 3

        await viewModel.jumpToOldestDisplayedAttentionToast()

        let calls = await client.calls
        XCTAssertEqual(calls.last?.params.values.compactMap(stringValue).first, "w2:p2")
        XCTAssertEqual(
            viewModel.attentionToasts.toasts.map(\.paneID.rawValue), ["w2:p4", "w2:p3", "w2:p1"],
            "the opened toast goes, and the one under the pill moves up into view"
        )
    }

    @MainActor
    func testOpeningTheOldestWithNothingUpSendsNothing() async {
        let clock = TestClock()
        let client = FocusRecordingClient()
        let viewModel = makeViewModel(client, clock: clock)
        viewModel.update(model: attentionModel(), connection: .live)

        await viewModel.jumpToOldestDisplayedAttentionToast()

        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
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
        kind: kind, subject: pane, breadcrumb: "repo-tools › agents", raisedAt: date
    )
}

private func stringValue(_ value: JSONValue) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
}
