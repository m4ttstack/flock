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

        // p1 started as the split's FIRST child (rects 0-40 vs 40-80 in
        // splitPairModel), so restoring it there after the default
        // second-child landing needs a trailing swap (F5 / R1's side rule).
        // That move crosses back from w9 into w1, re-keying the pane, so the
        // swap must reference it via a placeholder naming the move's own
        // step, never the literal "w9:p1" (N3 / OpPlan's own contract).
        XCTAssertEqual(executed.inverse.ops, [
            .movePaneToTab(PaneID(rawValue: "w9:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
            .swapPanes(PaneID.planPlaceholder(movedByStep: 0), PaneID(rawValue: "w1:p2")),
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

        // p1 started as the split's FIRST child, so the inverse needs a
        // trailing swap to land it back on that side (F5 / R1's side rule).
        XCTAssertEqual(executed.inverse.ops, [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
            .swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")),
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

    /// herdr's `tab.move`/`workspace.move` compute the actual resulting
    /// index as `source < insert ? insert - 1 : insert` (F2), so the
    /// inverse's own `insertIndex` must account for that gap, not just
    /// replay the prior index verbatim.
    private func threeTabModel() -> SessionModel {
        model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1"), tabRecord("w1:t2", workspace: "w1", number: 2), tabRecord("w1:t3", workspace: "w1", number: 3)],
            panes: [], layouts: []
        )
    }

    func testInverseOfMoveTabLeftwardIsThePriorIndexPlusOne() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.move", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        // t3 (priorIndex 2) moves to insertIndex 0: actual landing index is
        // 0 (source 2 is not < insert 0), which is before priorIndex, so the
        // inverse must overshoot to priorIndex + 1 = 3.
        let plan = OpPlan(ops: [.moveTab(TabID(rawValue: "w1:t3"), insertIndex: 0)], label: "Reorder tab leftward")
        let result = await engine.execute(plan, model: threeTabModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.moveTab(TabID(rawValue: "w1:t3"), insertIndex: 3)])
    }

    func testInverseOfMoveTabRightwardIsThePriorIndex() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "tab.move", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        // t1 (priorIndex 0) moves to insertIndex 2: actual landing index is
        // 1 (source 0 < insert 2, so actual = insert - 1 = 1), which is
        // after priorIndex, so the inverse is exactly priorIndex = 0.
        let plan = OpPlan(ops: [.moveTab(TabID(rawValue: "w1:t1"), insertIndex: 2)], label: "Reorder tab rightward")
        let result = await engine.execute(plan, model: threeTabModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.moveTab(TabID(rawValue: "w1:t1"), insertIndex: 0)])
    }

    private func threeWorkspaceModel() -> SessionModel {
        model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1"), workspaceRecord("w3", activeTab: "w3:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1"), tabRecord("w2:t1", workspace: "w2"), tabRecord("w3:t1", workspace: "w3")],
            panes: [], layouts: []
        )
    }

    func testInverseOfMoveWorkspaceLeftwardIsThePriorIndexPlusOne() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.move", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.moveWorkspace(WorkspaceID(rawValue: "w3"), insertIndex: 0)], label: "Reorder workspace leftward")
        let result = await engine.execute(plan, model: threeWorkspaceModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.moveWorkspace(WorkspaceID(rawValue: "w3"), insertIndex: 3)])
    }

    func testInverseOfMoveWorkspaceRightwardIsThePriorIndex() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "workspace.move", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(ops: [.moveWorkspace(WorkspaceID(rawValue: "w1"), insertIndex: 2)], label: "Reorder workspace rightward")
        let result = await engine.execute(plan, model: threeWorkspaceModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.moveWorkspace(WorkspaceID(rawValue: "w1"), insertIndex: 0)])
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
            XCTAssertEqual(executed.irreversible, plan.ops, "\(plan.label) must be reported as irreversible")
        }
    }

    /// R2/F6: a plan mixing a genuine close with something reversible still
    /// produces the reversible op's inverse, and names only the close as
    /// irreversible.
    func testMixedCloseAndRenameYieldsRenameInverseWithCloseMarkedIrreversible() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.close", withResultJSON: "{}")
        fake.respond(to: "tab.rename", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let closeOp = PrimitiveOp.closePane(PaneID(rawValue: "w1:p2"))
        let renameOp = PrimitiveOp.renameTab(TabID(rawValue: "w1:t1"), "builds")
        let plan = OpPlan(ops: [closeOp, renameOp], label: "Close then rename")
        let result = await engine.execute(plan, model: splitPairModel())
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [.renameTab(TabID(rawValue: "w1:t1"), "w1:t1")])
        XCTAssertEqual(executed.irreversible, [closeOp])
    }

    // MARK: - Bounce and migration inverses (R1/F1)

    /// A same-tab bounce (top edge: bounces then swaps, per GesturePlanner)
    /// inverts to another bounce landing on the original neighbor, not a
    /// raw same-tab `movePaneToTab` herdr would refuse outright.
    func testBounceInverseIsItselfABounceWithTheOriginalNeighborAndSwap() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"},"created_tab":{"tab_id":"w1:tTEMP"}}}"#)
        fake.respond(to: "tab.close", withResultJSON: "{}")
        fake.respond(to: "pane.swap", withResultJSON: #"{"swap":{"reason":null}}"#)
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let sameTabModel = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1", paneCount: 2)],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true), paneRecord("w1:p2", workspace: "w1", tab: "w1:t1")],
            layouts: [layout(
                workspace: "w1", tab: "w1:t1", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 40, 24), focused: true), paneRect("w1:p2", rect(40, 0, 40, 24))],
                splits: [splitInfo("s1", .right, 0.5, rect(0, 0, 80, 24))]
            )]
        )
        guard let forwardPlan = expectPlanSuccess(plan(
            dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p2"), .top), model: sameTabModel
        )) else { return }

        let result = await engine.execute(forwardPlan, model: sameTabModel)
        guard let executed = expectSuccess(result) else { return }

        XCTAssertEqual(executed.inverse.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
            .swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")),
        ])
    }

    /// A tab migration's origin tab is fully vacated (herdr auto-closes it),
    /// so its inverse cannot target that dead id: it recreates a new tab in
    /// the original workspace instead, replaying each pane's recorded
    /// neighbor/split/ratio with ids remapped to their resolved identities.
    func testMigrationInverseRecreatesTheOriginalTabInTheOriginalWorkspace() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        // Two distinct responses for the plan's two sequential pane.move
        // calls: the anchor's creates the destination tab, the second
        // pane's lands in it (no creation fields of its own).
        fake.respondSequence(to: "pane.move", withResultJSONs: [
            #"{"move_result":{"pane":{"pane_id":"w2:p1"},"created_workspace":{"workspace_id":"w2"},"created_tab":{"tab_id":"w2:t9"}}}"#,
            #"{"move_result":{"pane":{"pane_id":"w2:p2"}}}"#,
        ])
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let twoPaneModel = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1", paneCount: 2)],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true), paneRecord("w1:p2", workspace: "w1", tab: "w1:t1")],
            layouts: [layout(
                workspace: "w1", tab: "w1:t1", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 40, 24), focused: true), paneRect("w1:p2", rect(40, 0, 40, 24))],
                splits: [splitInfo("s1", .right, 0.5, rect(0, 0, 80, 24))]
            )]
        )
        guard let forwardPlan = expectPlanSuccess(plan(
            dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: twoPaneModel
        )) else { return }
        // Sanity: this is the 2-pane migration shape the fixture assumes.
        XCTAssertEqual(forwardPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: nil),
            .movePaneToTab(
                PaneID(rawValue: "w1:p2"), tab: TabID.planPlaceholder(createdByStep: 0),
                target: PaneID.planPlaceholder(movedByStep: 0), split: .right, ratio: 0.5
            ),
        ])

        let result = await engine.execute(forwardPlan, model: twoPaneModel)
        guard let executed = expectSuccess(result) else { return }

        // The anchor's own move (step 0) crosses back from w2 into w1,
        // re-keying it, so step 1's target must be a placeholder naming
        // step 0, never the literal "w2:p1" (N3).
        XCTAssertEqual(executed.inverse.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w2:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w2:p2"), tab: TabID.planPlaceholder(createdByStep: 0), target: PaneID.planPlaceholder(movedByStep: 0), split: .right, ratio: 0.5),
        ])
    }

    private func expectPlanSuccess(_ result: Result<OpPlan, PlanError>, file: StaticString = #filePath, line: UInt = #line) -> OpPlan? {
        switch result {
        case .success(let plan): return plan
        case .failure(let error): XCTFail("expected a plan, got \(error)", file: file, line: line); return nil
        }
    }

    // MARK: - Unresolved placeholders fail the plan (R3/F8)

    func testUnresolvedTabPlaceholderFailsBeforeAnyWireCall() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let badOp = PrimitiveOp.closeTab(TabID.planPlaceholder(createdByStep: 0))
        let plan = OpPlan(ops: [badOp], label: "Close placeholder tab")
        let result = await engine.execute(plan, model: splitPairModel())

        switch result {
        case .success:
            XCTFail("expected a failure")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "unresolved_placeholder")
            XCTAssertEqual(failure.failedOp, badOp)
            XCTAssertTrue(failure.executed.isEmpty)
        }
        XCTAssertTrue(fake.receivedRequests.isEmpty, "the sentinel must never reach the wire")
    }

    func testUnresolvedPanePlaceholderFailsBeforeAnyWireCall() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let badOp = PrimitiveOp.renamePane(PaneID.planPlaceholder(movedByStep: 0), "x")
        let plan = OpPlan(ops: [badOp], label: "Rename placeholder pane")
        let result = await engine.execute(plan, model: splitPairModel())

        switch result {
        case .success:
            XCTFail("expected a failure")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "unresolved_placeholder")
            XCTAssertEqual(failure.failedOp, badOp)
        }
        XCTAssertTrue(fake.receivedRequests.isEmpty, "the sentinel must never reach the wire")
    }

    /// F8: the tab_not_found-as-success rule is scoped to a placeholder tab
    /// id; a literal one naming a real, missing target is a genuine failure.
    func testLiteralCloseTabTabNotFoundIsStillAFailure() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.failNext(method: "tab.close", code: "tab_not_found", message: "no such tab")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let op = PrimitiveOp.closeTab(TabID(rawValue: "w1:t2"))
        let plan = OpPlan(ops: [op], label: "Close tab")
        let result = await engine.execute(plan, model: splitPairModel())

        switch result {
        case .success:
            XCTFail("expected a failure")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "tab_not_found")
            XCTAssertEqual(failure.failedOp, op)
        }
    }

    // MARK: - Unzoom focus hijack (F7)

    /// herdr's `pane.zoom` focuses the pane it unzoomed and switches the
    /// active workspace/tab to it; an unzoom that ran without the
    /// move-focus rule already retargeting focus must be corrected back to
    /// whatever was focused before the plan, as a trailing `focusPane`.
    func testUnzoomHijackIsCorrectedBackToTheOriginallyFocusedPane() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.zoom", withResultJSON: "{}")
        fake.respond(to: "tab.rename", withResultJSON: "{}")
        fake.respond(to: "pane.focus", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        // The plan's own op touches neither pane nor focus, so nothing else
        // would otherwise correct whatever pane.zoom just hijacked.
        let plan = OpPlan(ops: [.renameTab(TabID(rawValue: "w1:t1"), "builds")], label: "Rename", needsUnzoom: [TabID(rawValue: "w1:t1")])
        let result = await engine.execute(plan, model: splitPairModel(zoomedT1: true, focusedPaneID: "w1:p1"))
        _ = expectSuccess(result)

        let lastRequest = fake.receivedRequests.last!
        XCTAssertEqual(lastRequest.method, "pane.focus")
        XCTAssertEqual(requestParams(lastRequest)["pane_id"] as? String, "w1:p1")
    }

    func testUnzoomHijackCorrectionIsSkippedWhenTheMoveFocusRuleAlreadyRetargets() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.zoom", withResultJSON: "{}")
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w9:p1"},"created_workspace":{"workspace_id":"w9"},"created_tab":{"tab_id":"w9:t1"}}}"#)
        fake.respond(to: "pane.focus", withResultJSON: "{}")
        let engine = MutationEngine(client: HerdrClient(socketPath: fake.socketPath))

        let plan = OpPlan(
            ops: [.movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil)],
            label: "Move", needsUnzoom: [TabID(rawValue: "w1:t1")]
        )
        let result = await engine.execute(plan, model: splitPairModel(zoomedT1: true, focusedPaneID: "w1:p1"))
        _ = expectSuccess(result)

        // Exactly one trailing focusPane, targeting the moved pane's
        // resolved id -- not a second one for the pre-unzoom focus.
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "pane.focus" }.count, 1)
        let lastRequest = fake.receivedRequests.last!
        XCTAssertEqual(requestParams(lastRequest)["pane_id"] as? String, "w9:p1")
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
