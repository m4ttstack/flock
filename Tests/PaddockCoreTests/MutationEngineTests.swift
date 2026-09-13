import XCTest
@testable import PaddockCore

final class MutationEngineTests: XCTestCase {
    // MARK: - Fixture builders (mirrors GesturePlannerTests' pattern)

    private func paneRecord(_ id: String, workspace: String, tab: String, focused: Bool = false) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab),
            focused: focused, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
    }

    private func tabRecord(_ id: String, workspace: String, number: Int = 1, paneCount: Int = 1, label: String = "") -> TabRecord {
        TabRecord(tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), label: label.isEmpty ? id : label, number: number, paneCount: paneCount, agentStatus: .idle)
    }

    private func workspaceRecord(_ id: String, activeTab: String, number: Int = 1, label: String = "") -> WorkspaceRecord {
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: id), label: label.isEmpty ? id : label, number: number, activeTabID: TabID(rawValue: activeTab), agentStatus: .idle)
    }

    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CellRect {
        CellRect(x: x, y: y, width: w, height: h)
    }

    private func paneRect(_ id: String, _ rect: CellRect, focused: Bool = false) -> PaneRect {
        PaneRect(paneID: PaneID(rawValue: id), focused: focused, rect: rect)
    }

    private func splitInfo(_ id: String, _ direction: SplitDirection, _ ratio: Double, _ rect: CellRect) -> SplitInfo {
        SplitInfo(id: id, direction: direction, ratio: ratio, rect: rect)
    }

    private func layout(
        workspace: String, tab: String, zoomed: Bool = false, area: CellRect,
        focusedPane: String?, panes: [PaneRect], splits: [SplitInfo] = []
    ) -> LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab), zoomed: zoomed, area: area,
            focusedPaneID: focusedPane.map { PaneID(rawValue: $0) }, panes: panes, splits: splits
        )
    }

    private func model(
        workspaces: [WorkspaceRecord], tabs: [TabRecord], panes: [PaneRecord], layouts: [LayoutSnapshot],
        focusedPaneID: String? = nil
    ) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: focusedPaneID.map { PaneID(rawValue: $0) },
            workspaces: workspaces, tabs: tabs, panes: panes, layouts: layouts
        ))
    }

    /// w1:t1 has two panes (p1 | p2) split right 0.5; w1:t2 is a bare
    /// single-tab destination for moves that stay in the same workspace.
    private func splitPairModel(zoomedT1: Bool = false, focusedPaneID: String? = "w1:p1") -> SessionModel {
        model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1", paneCount: 2), tabRecord("w1:t2", workspace: "w1", number: 2, paneCount: 0)],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true), paneRecord("w1:p2", workspace: "w1", tab: "w1:t1")],
            layouts: [layout(
                workspace: "w1", tab: "w1:t1", zoomed: zoomedT1, area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 40, 24), focused: true), paneRect("w1:p2", rect(40, 0, 40, 24))],
                splits: [splitInfo("s1", .right, 0.5, rect(0, 0, 80, 24))]
            )],
            focusedPaneID: focusedPaneID
        )
    }

    private func requestParams(_ request: (method: String, paramsJSON: String)) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8))) as? [String: Any] ?? [:]
    }

    private func expectSuccess(_ result: Result<ExecutedPlan, OpFailure>, file: StaticString = #filePath, line: UInt = #line) -> ExecutedPlan? {
        switch result {
        case .success(let executed): return executed
        case .failure(let failure): XCTFail("expected success, got \(failure)", file: file, line: line); return nil
        }
    }

    // MARK: - Named test 1: unzoom runs before ops

    func testUnzoomRunsFirst() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.zoom", withResultJSON: "{}")
        fake.respond(to: "pane.focus", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.focusPane(PaneID(rawValue: "w1:p1"))], label: "Focus", needsUnzoom: [TabID(rawValue: "w1:t1")])
        let result = await engine.execute(plan, model: splitPairModel(zoomedT1: true, focusedPaneID: nil))
        _ = expectSuccess(result)

        XCTAssertEqual(fake.receivedRequests.count, 2)
        XCTAssertEqual(fake.receivedRequests[0].method, "pane.zoom")
        let zoomParams = requestParams(fake.receivedRequests[0])
        XCTAssertEqual(zoomParams["pane_id"] as? String, "w1:p1")
        XCTAssertEqual(zoomParams["mode"] as? String, "off")
        XCTAssertEqual(fake.receivedRequests[1].method, "pane.focus")
    }

    // MARK: - Named test 2: cross-workspace move threads the new id forward

    func testIdThreadingAcrossCrossWorkspaceMove() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w9:p1"},"created_workspace":{"workspace_id":"w9"},"created_tab":{"tab_id":"w9:t1"}}}"#)
        fake.respond(to: "pane.rename", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [
            .movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil),
            .renamePane(PaneID.planPlaceholder(movedByStep: 0), "renamed"),
        ], label: "Move then rename")
        // Not the focused pane, so no trailing pane.focus muddies "last request".
        let result = await engine.execute(plan, model: splitPairModel(focusedPaneID: "w1:p2"))
        _ = expectSuccess(result)

        let renameRequest = fake.receivedRequests.last!
        XCTAssertEqual(renameRequest.method, "pane.rename")
        XCTAssertEqual(requestParams(renameRequest)["pane_id"] as? String, "w9:p1", "a following op must target the resolved id, never the pre-move one")
    }

    // MARK: - Named test 3: inverse of movePaneToNewWorkspace uses resolved ids

    func testInverseUsesResolvedIds() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w9:p1"},"created_workspace":{"workspace_id":"w9"},"created_tab":{"tab_id":"w9:t1"}}}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil)], label: "Move pane to new workspace")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [
            .movePaneToTab(PaneID(rawValue: "w9:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
        ])
    }

    // MARK: - Named test 4: a failure stops the plan and reports what already ran

    func testFailureStopsAndReports() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.focus", withResultJSON: "{}")
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"changed":false,"reason":"zoomed_tab","pane":{"pane_id":"w1:p1"}}}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let firstOp = PrimitiveOp.focusPane(PaneID(rawValue: "w1:p1"))
        let secondOp = PrimitiveOp.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)
        let plan = OpPlan(ops: [firstOp, secondOp], label: "Focus then move")
        let result = await engine.execute(plan, model: splitPairModel())

        switch result {
        case .success:
            XCTFail("expected a failure")
        case .failure(let failure):
            XCTAssertEqual(failure.executed, [firstOp])
            XCTAssertEqual(failure.failedOp, secondOp)
            XCTAssertEqual(failure.code, "zoomed_tab")
        }
    }

    // MARK: - Bounce plan: placeholder substitution + tab_not_found-as-success

    func testBouncePlanSubstitutesCreatedTabAndTreatsTabNotFoundOnCloseAsSuccess() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"},"created_tab":{"tab_id":"w1:tTEMP"}}}"#)
        fake.failNext(method: "tab.close", code: "tab_not_found", message: "already gone")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .down, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
        ], label: "Move pane")
        // Not the focused pane, so no trailing pane.focus muddies "last request".
        let result = await engine.execute(plan, model: splitPairModel(focusedPaneID: "w1:p2"))
        _ = expectSuccess(result)

        let closeRequest = fake.receivedRequests.last!
        XCTAssertEqual(closeRequest.method, "tab.close")
        XCTAssertEqual(requestParams(closeRequest)["tab_id"] as? String, "w1:tTEMP", "the placeholder must resolve to the tab herdr actually created")
    }

    // MARK: - Inverse per op family

    func testInverseOfMovePaneToTabRestoresOriginalTabNeighborSplitAndRatio() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}}}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
        ])
    }

    func testInverseOfSwapPanesIsTheSameSwap() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.swap", withResultJSON: #"{"swap":{"reason":null}}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2"))], label: "Swap")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2"))])
    }

    func testInverseOfSetSplitRatioIsThePriorRatio() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [], ratio: 0.75)], label: "Resize")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [], ratio: 0.5)])
    }

    func testInverseOfMoveTabIsThePriorIndex() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.move", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.moveTab(TabID(rawValue: "w1:t2"), insertIndex: 0)], label: "Reorder tab")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.moveTab(TabID(rawValue: "w1:t2"), insertIndex: 1)])
    }

    func testInverseOfMoveWorkspaceIsThePriorIndex() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.move", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let twoWorkspaceModel = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1"), tabRecord("w2:t1", workspace: "w2")],
            panes: [], layouts: []
        )
        let plan = OpPlan(ops: [.moveWorkspace(WorkspaceID(rawValue: "w2"), insertIndex: 0)], label: "Reorder workspace")
        let result = await engine.execute(plan, model: twoWorkspaceModel)
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.moveWorkspace(WorkspaceID(rawValue: "w2"), insertIndex: 1)])
    }

    func testInverseOfRenamePaneIsThePriorLabelIncludingNilToClear() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.rename", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.renamePane(PaneID(rawValue: "w1:p1"), "scratch")], label: "Rename pane")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.renamePane(PaneID(rawValue: "w1:p1"), nil)], "the fixture pane started with no label, so undo must clear it back to nil")
    }

    func testInverseOfRenameTabIsThePriorLabel() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.rename", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.renameTab(TabID(rawValue: "w1:t1"), "builds")], label: "Rename tab")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.renameTab(TabID(rawValue: "w1:t1"), "w1:t1")])
    }

    func testInverseOfRenameWorkspaceIsThePriorLabel() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.rename", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.renameWorkspace(WorkspaceID(rawValue: "w1"), "repo-tools")], label: "Rename workspace")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.renameWorkspace(WorkspaceID(rawValue: "w1"), "w1")])
    }

    func testCloseOpsHaveNoInverse() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.close", withResultJSON: "{}")
        fake.respond(to: "tab.close", withResultJSON: "{}")
        fake.respond(to: "workspace.close", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        for plan in [
            OpPlan(ops: [.closePane(PaneID(rawValue: "w1:p2"))], label: "Close pane"),
            OpPlan(ops: [.closeTab(TabID(rawValue: "w1:t2"))], label: "Close tab"),
            OpPlan(ops: [.closeWorkspace(WorkspaceID(rawValue: "w1"), closeGroup: false)], label: "Close workspace"),
        ] {
            let result = await engine.execute(plan, model: splitPairModel())
            guard let executed = expectSuccess(result) else { continue }
            XCTAssertTrue(executed.inverse.ops.isEmpty, "\(plan.label) must have no inverse ops")
        }
    }

    // MARK: - Focus-follow rule

    func testFocusFollowsTheMovedPaneWhenItWasFocusedBeforeThePlan() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w9:p1"},"created_workspace":{"workspace_id":"w9"},"created_tab":{"tab_id":"w9:t1"}}}"#)
        fake.respond(to: "pane.focus", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil)], label: "Move")
        let result = await engine.execute(plan, model: splitPairModel(focusedPaneID: "w1:p1"))
        _ = expectSuccess(result)

        let lastRequest = fake.receivedRequests.last!
        XCTAssertEqual(lastRequest.method, "pane.focus", "pane.move never focuses the pane it moved, so the executor must restore focus itself")
        XCTAssertEqual(requestParams(lastRequest)["pane_id"] as? String, "w9:p1")
    }

    func testFocusIsNotRestoredWhenTheMovedPaneWasNotFocused() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w9:p1"},"created_workspace":{"workspace_id":"w9"},"created_tab":{"tab_id":"w9:t1"}}}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil)], label: "Move")
        let result = await engine.execute(plan, model: splitPairModel(focusedPaneID: "w1:p2"))
        _ = expectSuccess(result)

        XCTAssertFalse(fake.receivedRequests.contains { $0.method == "pane.focus" })
    }
}
