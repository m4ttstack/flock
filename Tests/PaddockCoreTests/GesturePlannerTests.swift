import XCTest
@testable import PaddockCore

final class GesturePlannerTests: XCTestCase {
    // MARK: - Fixture builders

    private func paneRecord(_ id: String, workspace: String, tab: String, focused: Bool = false) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab),
            focused: focused, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
    }

    private func tabRecord(_ id: String, workspace: String, number: Int = 1, paneCount: Int = 1) -> TabRecord {
        TabRecord(tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), label: id, number: number, paneCount: paneCount, agentStatus: .idle)
    }

    private func workspaceRecord(_ id: String, activeTab: String, number: Int = 1) -> WorkspaceRecord {
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: id), label: id, number: number, activeTabID: TabID(rawValue: activeTab), agentStatus: .idle)
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

    private func model(workspaces: [WorkspaceRecord], tabs: [TabRecord], panes: [PaneRecord], layouts: [LayoutSnapshot]) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: workspaces, tabs: tabs, panes: panes, layouts: layouts
        ))
    }

    /// w1 has t1 (pane p1) and t2 (pane p2), full-tab single panes. w2 exists
    /// but is empty. `zoomedT1`/`zoomedT2` let tests flag either tab zoomed.
    private func twoTabModel(zoomedT1: Bool = false, zoomedT2: Bool = false) -> SessionModel {
        model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1"), tabRecord("w1:t2", workspace: "w1", number: 2)],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true), paneRecord("w1:p2", workspace: "w1", tab: "w1:t2", focused: true)],
            layouts: [
                layout(workspace: "w1", tab: "w1:t1", zoomed: zoomedT1, area: rect(0, 0, 80, 24), focusedPane: "w1:p1", panes: [paneRect("w1:p1", rect(0, 0, 80, 24), focused: true)]),
                layout(workspace: "w1", tab: "w1:t2", zoomed: zoomedT2, area: rect(0, 0, 80, 24), focusedPane: "w1:p2", panes: [paneRect("w1:p2", rect(0, 0, 80, 24), focused: true)]),
            ]
        )
    }

    private func expectPlan(_ result: Result<OpPlan, PlanError>, file: StaticString = #filePath, line: UInt = #line) -> OpPlan? {
        switch result {
        case .success(let plan): return plan
        case .failure(let error):
            XCTFail("expected a plan, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Named test 1: left edge, cross-tab, composes split then swap

    func testLeftEdgeCrossTabComposesSplitThenSwap() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p2"), .left), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
            .swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")),
        ])
    }

    // MARK: - Named tests 2-4: same-tab bounce

    func testSameTabBottomEdgeUsesBounce() {
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
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p2"), .bottom), model: sameTabModel)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .down, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
        ])
    }

    func testSameTabRightEdgeUsesBounce() {
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
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p2"), .right), model: sameTabModel)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
        ])
    }

    func testSameTabTopEdgeBouncesThenSwaps() {
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
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p2"), .top), model: sameTabModel)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p2"), split: .down, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
            .swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")),
        ])
    }

    // MARK: - Named test 5: tab thumbnail drop targets the focused pane

    func testTabThumbnailDropTargetsFocusedPane() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .tabThumbnail(TabID(rawValue: "w1:t2")), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: 0.5),
        ])
    }

    // MARK: - Named test 6: workspace thumbnail drop makes a new tab

    func testWorkspaceThumbnailDropMakesNewTab() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: nil),
        ])
    }

    // MARK: - Named test 7: drop on self is a no-op

    func testDropOnSelfIsNoOp() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneInterior(PaneID(rawValue: "w1:p1")), model: model)
        switch result {
        case .failure(.noOp): break
        default: XCTFail("expected .noOp, got \(result)")
        }
    }

    // MARK: - Named test 8: zoomed target tab is listed in needsUnzoom

    func testZoomedTargetListedInNeedsUnzoom() {
        let model = twoTabModel(zoomedT2: true)
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneInterior(PaneID(rawValue: "w1:p2")), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.needsUnzoom, [TabID(rawValue: "w1:t2")])
    }

    // MARK: - Named test 9: tab migration preserves split shape

    func testTabMigrationPreservesSplitShape() {
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
        let twoPaneResult = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: twoPaneModel)
        guard let twoPanePlan = expectPlan(twoPaneResult) else { return }
        XCTAssertEqual(twoPanePlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: nil),
            .movePaneToTab(
                PaneID(rawValue: "w1:p2"), tab: TabID.planPlaceholder(createdByStep: 0),
                target: PaneID.planPlaceholder(movedByStep: 0), split: .right, ratio: 0.5
            ),
        ])

        // Nested: root splits right into (nested-down-split | p3); nested splits down into (p1 | p2).
        let nestedModel = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1", paneCount: 3)],
            panes: [
                paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true),
                paneRecord("w1:p2", workspace: "w1", tab: "w1:t1"),
                paneRecord("w1:p3", workspace: "w1", tab: "w1:t1"),
            ],
            layouts: [layout(
                workspace: "w1", tab: "w1:t1", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [
                    paneRect("w1:p1", rect(0, 0, 40, 12), focused: true),
                    paneRect("w1:p2", rect(0, 12, 40, 12)),
                    paneRect("w1:p3", rect(40, 0, 40, 24)),
                ],
                splits: [
                    splitInfo("root", .right, 0.5, rect(0, 0, 80, 24)),
                    splitInfo("nested", .down, 0.5, rect(0, 0, 40, 24)),
                ]
            )]
        )
        let nestedResult = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: nestedModel)
        guard let nestedPlan = expectPlan(nestedResult) else { return }
        XCTAssertEqual(nestedPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: nil),
            .movePaneToTab(
                PaneID(rawValue: "w1:p3"), tab: TabID.planPlaceholder(createdByStep: 0),
                target: PaneID.planPlaceholder(movedByStep: 0), split: .right, ratio: 0.5
            ),
            .movePaneToTab(
                PaneID(rawValue: "w1:p2"), tab: TabID.planPlaceholder(createdByStep: 0),
                target: PaneID.planPlaceholder(movedByStep: 0), split: .down, ratio: 0.5
            ),
        ])
    }

    // MARK: - Extra rules: pane -> paneInterior

    func testInteriorSameTabSwap() {
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
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneInterior(PaneID(rawValue: "w1:p2")), model: sameTabModel)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.swapPanes(PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2"))])
    }

    func testInteriorCrossTabMove() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneInterior(PaneID(rawValue: "w1:p2")), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: PaneID(rawValue: "w1:p2"), split: .right, ratio: 0.5),
        ])
    }

    // MARK: - Extra rules: pane -> newTab / newWorkspace

    func testPaneToNewTabIsSingleOp() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .newTab(WorkspaceID(rawValue: "w2")), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: nil)])
    }

    func testPaneToNewWorkspaceIsSingleOp() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .newWorkspace, model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.movePaneToNewWorkspace(PaneID(rawValue: "w1:p1"), label: nil, tabLabel: nil)])
    }

    // MARK: - Extra rules: tab -> tabStrip, workspace -> rail

    func testTabToTabStripMovesTab() {
        let model = twoTabModel()
        let result = plan(dragging: .tab(TabID(rawValue: "w1:t2")), onto: .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveTab(TabID(rawValue: "w1:t2"), insertIndex: 0)])
    }

    func testWorkspaceToRailMovesWorkspace() {
        let model = twoTabModel()
        let result = plan(dragging: .workspace(WorkspaceID(rawValue: "w2")), onto: .workspaceRail(insertIndex: 0), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveWorkspace(WorkspaceID(rawValue: "w2"), insertIndex: 0)])
    }

    // MARK: - Invalid combinations

    func testTabOntoPaneEdgeIsInvalidCombination() {
        let model = twoTabModel()
        let result = plan(dragging: .tab(TabID(rawValue: "w1:t2")), onto: .paneEdge(PaneID(rawValue: "w1:p1"), .left), model: model)
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
    }

    func testWorkspaceOntoTabStripIsInvalidCombination() {
        let model = twoTabModel()
        let result = plan(dragging: .workspace(WorkspaceID(rawValue: "w2")), onto: .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0), model: model)
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
    }
}
