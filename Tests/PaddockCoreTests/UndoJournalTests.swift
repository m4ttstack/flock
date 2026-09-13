import XCTest
@testable import PaddockCore

@MainActor
private final class FakePlanExecutor: PlanExecuting {
    private(set) var executedPlans: [OpPlan] = []
    /// Queued in call order; a call past the end of the queue falls back to
    /// a trivial success (the plan itself, empty inverse) -- adequate for
    /// tests that don't care what a specific call returns.
    var queuedResults: [Result<ExecutedPlan, OpFailure>] = []

    func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        executedPlans.append(plan)
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: [], label: "Undo \(plan.label)")))
    }
}

final class UndoJournalTests: XCTestCase {
    // MARK: - Fixture (mirrors GesturePlannerTests/MutationEngineTests' pattern)

    private func paneRecord(_ id: String, workspace: String, tab: String) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab),
            focused: false, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
    }

    private func tabRecord(_ id: String, workspace: String) -> TabRecord {
        TabRecord(tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), label: id, number: 1, paneCount: 1, agentStatus: .idle)
    }

    private func workspaceRecord(_ id: String, activeTab: String) -> WorkspaceRecord {
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: id), label: id, number: 1, activeTabID: TabID(rawValue: activeTab), agentStatus: .idle)
    }

    /// w1:t1 has p1, w1:t2 has p2 -- enough to reference two panes and two
    /// tabs across a single workspace.
    private func fixtureModel() -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1"), tabRecord("w1:t2", workspace: "w1")],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1"), paneRecord("w1:p2", workspace: "w1", tab: "w1:t2")],
            layouts: []
        ))
    }

    // MARK: - undo executes the inverse through the executor

    @MainActor
    func testUndoExecutesTheInverseThroughTheExecutor() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        let inverse = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo move")
        journal.record(ExecutedPlan(plan: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Move"), inverse: inverse))

        await journal.undo()

        XCTAssertEqual(executor.executedPlans, [inverse])
    }

    // MARK: - redo re-executes the original plan

    @MainActor
    func testRedoReExecutesTheOriginalPlan() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        let originalPlan = OpPlan(ops: [.movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil)], label: "Move to new tab")
        let inversePlan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: nil, split: .right, ratio: 0.5)], label: "Undo move to new tab")
        journal.record(ExecutedPlan(plan: originalPlan, inverse: inversePlan))

        // Undoing runs `inversePlan`; queue what that run itself reports so
        // the ExecutedPlan pushed onto the redo stack carries `originalPlan`
        // as ITS OWN inverse -- exactly what a real `MutationEngine` run
        // would resolve fresh, placeholders included.
        executor.queuedResults = [.success(ExecutedPlan(plan: inversePlan, inverse: originalPlan))]

        await journal.undo()
        XCTAssertTrue(journal.canRedo)

        await journal.redo()

        XCTAssertEqual(executor.executedPlans, [inversePlan, originalPlan])
    }

    // MARK: - stale entry dropped with a notice

    @MainActor
    func testStaleEntryIsSkippedAndRemovedWithANotice() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        let inverse = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p99"))], label: "Undo move")
        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move a pane that is now gone"), inverse: inverse))

        await journal.undo()

        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertFalse(journal.canUndo)
        XCTAssertFalse(journal.canRedo)
        XCTAssertEqual(notices, ["Can't undo: Move a pane that is now gone, panes changed"])
    }

    // MARK: - irreversible entry undone reports partial

    @MainActor
    func testUndoingAnIrreversibleEntryNoticesThePartialUndo() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        let pane = PaneID(rawValue: "w1:p1")
        journal.record(ExecutedPlan(
            plan: OpPlan(ops: [.closePane(pane)], label: "Close pane"),
            inverse: OpPlan(ops: [], label: "Undo Close pane"),
            irreversible: [.closePane(pane)]
        ))

        await journal.undo()

        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [], label: "Undo Close pane")])
        XCTAssertEqual(notices, ["Undo Close pane partially: the pane close not undone"])
    }

    // MARK: - depth 50 evicts the oldest entry

    @MainActor
    func testDepthFiftyEvictsTheOldestEntry() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })

        for i in 1...51 {
            journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move \(i)"), inverse: OpPlan(ops: [], label: "Undo Move \(i)")))
        }

        XCTAssertEqual(journal.undoLabel, "Move 51")
        for _ in 1...50 {
            await journal.undo()
        }
        // If "Move 1" had NOT been evicted, a 51st undo would still find it;
        // since depth is exactly 50, the stack is already empty here.
        XCTAssertFalse(journal.canUndo)
    }

    // MARK: - a new record clears the redo stack

    @MainActor
    func testRecordingClearsTheRedoStack() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 1"), inverse: OpPlan(ops: [], label: "Undo Move 1")))
        await journal.undo()
        XCTAssertTrue(journal.canRedo)

        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 2"), inverse: OpPlan(ops: [], label: "Undo Move 2")))

        XCTAssertFalse(journal.canRedo)
    }
}
