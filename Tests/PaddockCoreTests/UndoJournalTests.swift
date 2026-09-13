import XCTest
@testable import PaddockCore

@MainActor
private final class FakePlanExecutor: PlanExecuting {
    private(set) var executedPlans: [OpPlan] = []
    /// Queued in call order; a call past the end of the queue falls back to
    /// a trivial success (the plan itself, empty inverse, no remap) --
    /// adequate for tests that don't care what a specific call returns.
    var queuedResults: [Result<ExecutedPlan, OpFailure>] = []

    private var holdEnabled = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Every subsequent `execute` call suspends until `releaseNext()`
    /// resumes it, one call at a time (FIFO) -- lets a test observe that a
    /// second call has not yet reached the executor while the first is
    /// still in flight.
    func hold() { holdEnabled = true }

    func releaseNext() {
        guard !pendingContinuations.isEmpty else { return }
        pendingContinuations.removeFirst().resume()
    }

    func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        executedPlans.append(plan)
        if holdEnabled {
            await withCheckedContinuation { pendingContinuations.append($0) }
        }
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

    // MARK: - redo re-executes the ORIGINAL plan, never the inverse-of-inverse

    @MainActor
    func testRedoReExecutesTheOriginalPlan() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        let originalPlan = OpPlan(ops: [.movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil)], label: "Move to new tab")
        let inversePlan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: nil, split: .right, ratio: 0.5)], label: "Undo move to new tab")
        journal.record(ExecutedPlan(plan: originalPlan, inverse: inversePlan))

        // Left at the executor's default behavior (success, trivial "Undo
        // <label>" inverse, no remap): the journal's OWN bookkeeping -- undo
        // requeues the ORIGINAL entry onto redo, never the result of running
        // the inverse -- is what makes `redo()` execute `originalPlan`
        // itself, not some doubled-back "undo of the undo".
        await journal.undo()
        XCTAssertTrue(journal.canRedo)
        XCTAssertEqual(journal.redoLabel, "Move to new tab", "the redo label must read the FORWARD action, not \"Undo ...\"")

        await journal.redo()

        XCTAssertEqual(executor.executedPlans, [inversePlan, originalPlan])
    }

    @MainActor
    func testRedoOfANewTabPlanNeverReferencesTheDeadFirstCreatedTab() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        let originalPlan = OpPlan(ops: [.movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil)], label: "Move to new tab")
        // Mirrors what MutationEngine's own fix for a lone pane's move now
        // produces: the inverse of "move to a new tab" is ALSO a
        // `movePaneToNewTab`, never a `movePaneToTab` back into a tab id
        // that died the moment its last pane left.
        let inversePlan = OpPlan(ops: [.movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil)], label: "Undo Move to new tab (into a new tab)")
        journal.record(ExecutedPlan(plan: originalPlan, inverse: inversePlan))

        await journal.undo()
        await journal.redo()

        XCTAssertEqual(executor.executedPlans, [inversePlan, originalPlan])
    }

    @MainActor
    func testRedoSubstitutesTheRemappedPaneIDAfterACrossWorkspaceUndo() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })

        let originalID = PaneID(rawValue: "w1:pOriginal")   // this plan's own literal reference -- need not exist live
        let midID = PaneID(rawValue: "w1:p1")               // what `originalID` became once the original plan first ran
        let finalID = PaneID(rawValue: "w1:p2")              // what `midID` becomes once undo's own inverse re-keys it again

        let originalPlan = OpPlan(ops: [.movePaneToNewWorkspace(originalID, label: nil, tabLabel: nil)], label: "Move to new workspace")
        let inversePlan = OpPlan(ops: [.movePaneToTab(midID, tab: TabID(rawValue: "w1:t1"), target: nil, split: .right, ratio: 0.5)], label: "Undo Move to new workspace")
        journal.record(ExecutedPlan(plan: originalPlan, inverse: inversePlan, paneIDRemap: [originalID: midID]))

        executor.queuedResults = [
            .success(ExecutedPlan(plan: inversePlan, inverse: OpPlan(ops: [], label: "x"), paneIDRemap: [midID: finalID])),
        ]

        await journal.undo()
        await journal.redo()

        XCTAssertEqual(executor.executedPlans, [
            inversePlan,
            OpPlan(ops: [.movePaneToNewWorkspace(finalID, label: nil, tabLabel: nil)], label: "Move to new workspace"),
        ])
    }

    @MainActor
    func testRedoRecomputesNeedsUnzoomFreshRatherThanCopyingTheStaleRecordedList() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        // Recorded while "w1:t1" was zoomed; the fixture model is NOT
        // zoomed, so a redo must NOT replay this stale list -- herdr's own
        // zoom handler still focuses the pane it unzoomed even when the
        // unzoom is a no-op, so replaying a stale entry here is a visible
        // focus hijack, not a harmless no-op.
        let originalPlan = OpPlan(
            ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Move",
            needsUnzoom: [TabID(rawValue: "w1:t1")]
        )
        let inversePlan = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Undo Move")
        journal.record(ExecutedPlan(plan: originalPlan, inverse: inversePlan))

        await journal.undo()
        await journal.redo()

        XCTAssertEqual(executor.executedPlans.last?.needsUnzoom, [])
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

    // MARK: - a nil (not-yet-connected) model restores the entry, never drops it

    @MainActor
    func testUndoWithNoModelRestoresTheEntryAndReportsNotConnected() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        var currentModel: SessionModel?
        let journal = UndoJournal(executor: executor, model: { currentModel }, notify: { notices.append($0) })
        let inverse = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo move")
        journal.record(ExecutedPlan(plan: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Move"), inverse: inverse))

        await journal.undo()

        XCTAssertTrue(journal.canUndo, "a transient nil model must restore the entry, not drop it")
        XCTAssertFalse(journal.canRedo)
        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertEqual(notices, ["Can't undo: Move, not connected"])

        currentModel = fixtureModel()
        await journal.undo()

        XCTAssertEqual(executor.executedPlans, [inverse])
    }

    // MARK: - a failure with nothing executed is transient too -- restore for retry

    @MainActor
    func testFailedUndoWithNothingExecutedRestoresTheEntryForRetry() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        let inverse = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo move")
        journal.record(ExecutedPlan(plan: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Move"), inverse: inverse))
        executor.queuedResults = [.failure(OpFailure(
            failedOp: inverse.ops[0], code: "transport_error", message: "boom", executed: [], partialInverse: OpPlan(ops: [], label: "x")
        ))]

        await journal.undo()

        XCTAssertTrue(journal.canUndo, "nothing reached herdr -- the entry must be restored so the user can retry")
        XCTAssertEqual(notices, ["Can't undo Move: boom"])

        // A subsequent (now-succeeding) undo runs the SAME inverse again.
        await journal.undo()
        XCTAssertEqual(executor.executedPlans, [inverse, inverse])
    }

    @MainActor
    func testFailedRedoWithNothingExecutedRestoresTheEntryForRetry() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        let originalPlan = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Move")
        journal.record(ExecutedPlan(plan: originalPlan, inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo move")))
        await journal.undo()
        notices.removeAll()

        executor.queuedResults = [.failure(OpFailure(
            failedOp: originalPlan.ops[0], code: "transport_error", message: "boom", executed: [], partialInverse: OpPlan(ops: [], label: "x")
        ))]

        await journal.redo()

        XCTAssertTrue(journal.canRedo, "nothing reached herdr -- the entry must be restored so the user can retry")
        XCTAssertEqual(notices, ["Can't redo Move: boom"])

        await journal.redo()
        XCTAssertEqual(executor.executedPlans.last, originalPlan)
    }

    // MARK: - undoing a pure close is a no-op; a MIXED entry still reports partial

    @MainActor
    func testUndoingAPureCloseDoesNothingAndDropsTheEntryWithoutTouchingTheExecutor() async {
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

        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertFalse(journal.canUndo)
        XCTAssertFalse(journal.canRedo)
        XCTAssertEqual(notices, ["Nothing to undo for Close pane: closes are final"])
    }

    @MainActor
    func testUndoingAMixedEntryStillNoticesThePartialUndo() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        let pane = PaneID(rawValue: "w1:p1")
        let closed = PaneID(rawValue: "w1:p2")
        journal.record(ExecutedPlan(
            plan: OpPlan(ops: [.closePane(closed), .focusPane(pane)], label: "Close and refocus"),
            inverse: OpPlan(ops: [.focusPane(pane)], label: "Undo Close and refocus"),
            irreversible: [.closePane(closed)]
        ))

        await journal.undo()

        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.focusPane(pane)], label: "Undo Close and refocus")])
        XCTAssertEqual(notices, ["Undo Close and refocus partially: the pane close not undone"])
    }

    /// An empty inverse is not ALWAYS a close: `MutationEngine.simpleInverse`
    /// has no inverse for a bare focus/zoom op either, and those are never
    /// marked irreversible -- "closes are final" must not be said about them.
    @MainActor
    func testUndoingAnEmptyInverseThatIsNotACloseUsesThePlainNotice() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        journal.record(ExecutedPlan(
            plan: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Focus pane"),
            inverse: OpPlan(ops: [], label: "Undo Focus pane")
        ))

        await journal.undo()

        XCTAssertEqual(notices, ["Nothing to undo for Focus pane"])
    }

    // MARK: - a lost-position undo notices that the pane landed in a new tab

    @MainActor
    func testUndoingAPositionLostEntryNoticesTheNewTabRestore() async {
        let executor = FakePlanExecutor()
        var notices: [String] = []
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { notices.append($0) })
        journal.record(ExecutedPlan(
            plan: OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move pane into tab"),
            inverse: OpPlan(ops: [.movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil)], label: "Undo Move pane into tab (into a new tab)"),
            positionLost: true
        ))

        await journal.undo()

        XCTAssertEqual(notices, ["Undone into a new tab (original position not restorable)"])
        XCTAssertTrue(journal.canRedo, "the entry is still redoable even though its position was lost")
    }

    // MARK: - depth 50 evicts the oldest entry

    @MainActor
    func testDepthFiftyEvictsTheOldestEntry() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })

        for i in 1...51 {
            journal.record(ExecutedPlan(
                plan: OpPlan(ops: [], label: "Move \(i)"),
                inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo Move \(i)")
            ))
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
        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 1"), inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo Move 1")))
        await journal.undo()
        XCTAssertTrue(journal.canRedo)

        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 2"), inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Undo Move 2")))

        XCTAssertFalse(journal.canRedo)
    }

    // MARK: - isBusy covers the whole chain (drives the Edit menu's disabled state)

    @MainActor
    func testIsBusyIsTrueOnlyWhileAStepIsInFlight() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 1"), inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo Move 1")))

        XCTAssertFalse(journal.isBusy)
        executor.hold()
        let task = Task { await journal.undo() }
        await Self.waitUntil { executor.executedPlans.count == 1 }
        XCTAssertTrue(journal.isBusy)

        executor.releaseNext()
        await task.value

        XCTAssertFalse(journal.isBusy)
    }

    // MARK: - two back-to-back undos serialize instead of racing

    @MainActor
    func testTwoBackToBackUndosExecuteSequentiallyInOrder() async {
        let executor = FakePlanExecutor()
        let journal = UndoJournal(executor: executor, model: { self.fixtureModel() }, notify: { _ in })
        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 1"), inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo Move 1")))
        journal.record(ExecutedPlan(plan: OpPlan(ops: [], label: "Move 2"), inverse: OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Undo Move 2")))

        executor.hold()
        let first = Task { await journal.undo() }
        await Self.waitUntil { executor.executedPlans.count == 1 }

        let second = Task { await journal.undo() }
        // `second` is structurally blocked on `first`'s own chained task,
        // not on scheduling luck: it cannot reach the executor no matter
        // how long this waits, until `first`'s hold is released.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(executor.executedPlans.count, 1, "a second undo must not reach the executor while the first is still in flight")

        executor.releaseNext()
        await Self.waitUntil { executor.executedPlans.count == 2 }
        executor.releaseNext()
        await first.value
        await second.value

        XCTAssertEqual(executor.executedPlans, [
            OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p2"))], label: "Undo Move 2"),
            OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Undo Move 1"),
        ])
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }
}
