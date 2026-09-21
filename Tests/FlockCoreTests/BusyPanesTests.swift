import XCTest
@testable import FlockCore

/// `tabs` is each tab's id paired with its panes, each pane an id and the
/// agent status herdr reports for it.
private func makeModel(tabs: [(String, [(String, String)])]) -> SessionModel {
    let tabJSON = tabs.enumerated().map { index, entry in
        #"{"tab_id":"\#(entry.0)","workspace_id":"w1","label":"\#(index + 1)","number":\#(index + 1),"pane_count":\#(entry.1.count),"agent_status":"unknown"}"#
    }
    let paneJSON = tabs.flatMap { entry in
        entry.1.map { pane in
            #"{"pane_id":"\#(pane.0)","workspace_id":"w1","tab_id":"\#(entry.0)","focused":false,"agent_status":"\#(pane.1)","revision":0,"cwd":"/tmp"}"#
        }
    }
    let snapshotJSON = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"\#(tabs[0].0)","focused_pane_id":null,"workspaces":[{"workspace_id":"w1","label":"seed","number":4,"active_tab_id":"\#(tabs[0].0)","agent_status":"unknown"}],"tabs":[\#(tabJSON.joined(separator: ","))],"panes":[\#(paneJSON.joined(separator: ","))],"layouts":[]}
    """#
    let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
    return SessionModel(snapshot: snapshot)
}

/// Closing a pane that is mid-task used to go straight out with nothing on
/// screen, because nothing escalated. The container is cheap and the work in
/// it is not, so that is exactly the case worth asking about.
final class BusyPanesTests: XCTestCase {
    private func busy(closing subject: CloseSubject, in model: SessionModel) -> BusyPanes {
        BusyPanes(closing: subject, consequence: CloseConsequence.of(subject, model: model), model: model)
    }

    /// Two tabs, so neither a pane close nor a tab close escalates and the
    /// busy count is the only thing that could raise a prompt.
    private func twoTabModel(_ p1: String, _ p2: String, _ p3: String) -> SessionModel {
        makeModel(tabs: [("w1:t1", [("w1:p1", p1), ("w1:p2", p2)]), ("w1:t2", [("w1:p3", p3)])])
    }

    func testAWorkingPaneCounts() {
        let model = twoTabModel("working", "idle", "idle")

        let busy = busy(closing: .pane(PaneID(rawValue: "w1:p1")), in: model)

        XCTAssertEqual(busy.working, 1)
        XCTAssertEqual(busy.count, 1)
    }

    /// A pane waiting on the user is holding a decision, and throwing that
    /// away is the same loss as throwing away work in flight.
    func testABlockedPaneCounts() {
        let model = twoTabModel("blocked", "idle", "idle")

        XCTAssertEqual(busy(closing: .pane(PaneID(rawValue: "w1:p1")), in: model).blocked, 1)
    }

    /// The deliberate gap. herdr reports a plain shell as `unknown`, so
    /// counting it would prompt on nearly every close, including a pane
    /// holding an idle prompt. The cost is that a shell running a long build
    /// closes silently.
    func testIdleDoneAndUnknownDoNotCount() {
        for status in ["idle", "done", "unknown"] {
            let model = twoTabModel(status, "idle", "idle")

            XCTAssertTrue(
                busy(closing: .pane(PaneID(rawValue: "w1:p1")), in: model).isEmpty,
                "\(status) must not raise a prompt"
            )
        }
    }

    /// Closing a pane weighs that pane, not its neighbours: the sibling keeps
    /// running and nothing of it is lost.
    func testAPaneCloseIgnoresABusySibling() {
        let model = twoTabModel("idle", "working", "idle")

        XCTAssertTrue(busy(closing: .pane(PaneID(rawValue: "w1:p1")), in: model).isEmpty)
    }

    /// A tab close takes every pane in it, so every one of them is weighed,
    /// and only those.
    func testATabCloseWeighsEveryPaneInTheTabAndNoOthers() {
        let model = twoTabModel("working", "blocked", "working")

        let busy = busy(closing: .tab(TabID(rawValue: "w1:t1")), in: model)

        XCTAssertEqual(busy.working, 1)
        XCTAssertEqual(busy.blocked, 1)
        XCTAssertEqual(busy.count, 2, "the pane in the other tab is not this tab's to lose")
    }

    /// An escalating close and a busy pane are independent reasons to ask,
    /// and the prompt has to say both: they are different losses.
    func testAnEscalatingCloseWithABusyPaneSaysBothThings() {
        let model = makeModel(tabs: [("w1:t1", [("w1:p1", "working")]), ("w1:t2", [("w1:p2", "idle")])])
        let subject = CloseSubject.pane(PaneID(rawValue: "w1:p1"))
        let consequence = CloseConsequence.of(subject, model: model)

        let confirmation = consequence.confirmation(
            closing: subject, busy: busy(closing: subject, in: model)
        )

        let message = try? XCTUnwrap(confirmation?.message)
        XCTAssertEqual(message?.contains("closes the tab"), true, "the escalation half is missing")
        XCTAssertEqual(message?.contains("still working"), true, "the interruption half is missing")
    }

    /// The quiet path has to stay quiet: nothing escalating and nothing busy
    /// means no prompt at all, which is most closes.
    func testAQuietCloseStillRaisesNothing() {
        let model = twoTabModel("idle", "idle", "idle")
        let subject = CloseSubject.pane(PaneID(rawValue: "w1:p1"))

        XCTAssertNil(
            CloseConsequence.of(subject, model: model)
                .confirmation(closing: subject, busy: busy(closing: subject, in: model))
        )
    }

    func testTheSentenceCountsRatherThanNames() {
        XCTAssertEqual(BusyPanes(working: 1, blocked: 0).sentence, "1 pane is still working.")
        XCTAssertEqual(BusyPanes(working: 3, blocked: 0).sentence, "3 panes are still working.")
        XCTAssertEqual(BusyPanes(working: 0, blocked: 1).sentence, "1 pane is waiting for you.")
        XCTAssertEqual(
            BusyPanes(working: 2, blocked: 1).sentence,
            "2 panes are still working and 1 waiting for you."
        )
        XCTAssertNil(BusyPanes.none.sentence)
    }

    /// The group close counts only the primary workspace, because nothing in
    /// the model says which workspaces are its linked worktrees, so its
    /// wording stops short of claiming a total.
    func testTheGroupSentenceScopesItselfToOneWorkspace() {
        XCTAssertEqual(
            BusyPanes(working: 2, blocked: 0).groupSentence,
            "2 panes are still working in this workspace."
        )
        XCTAssertNil(BusyPanes.none.groupSentence)
    }

    func testTheGroupCountCoversTheWholeWorkspace() {
        let model = twoTabModel("working", "idle", "blocked")

        let busy = BusyPanes(inWorkspace: WorkspaceID(rawValue: "w1"), model: model)

        XCTAssertEqual(busy.working, 1)
        XCTAssertEqual(busy.blocked, 1, "a busy pane in another tab of the same workspace still counts")
    }
}
