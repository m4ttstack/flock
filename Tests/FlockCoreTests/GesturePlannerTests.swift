import XCTest
@testable import FlockCore

final class GesturePlannerTests: XCTestCase {
    // MARK: - Fixture builders

    private func paneRecord(_ id: String, workspace: String, tab: String, focused: Bool = false) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab),
            focused: focused, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
    }

    /// `label` defaults to what herdr reports for a tab nobody has renamed:
    /// its own 1-based position, which these fixtures place at `number`.
    private func tabRecord(_ id: String, workspace: String, number: Int = 1, paneCount: Int = 1, label: String? = nil) -> TabRecord {
        TabRecord(
            tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace),
            label: label ?? String(number), number: number, paneCount: paneCount, agentStatus: .idle
        )
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

    /// The same composition on the other axis. Asserted separately from the
    /// left one because the two differ in the direction they split, and a
    /// mapping that lost the swap for one edge alone would still pass the
    /// other's case.
    func testTopEdgeCrossTabComposesSplitDownThenSwap() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p2"), .top), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: PaneID(rawValue: "w1:p2"), split: .down, ratio: 0.5),
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

    /// The fourth corner of the same-tab table, and the only one of the four
    /// that had no case: the bounce plus the swap, splitting right.
    func testSameTabLeftEdgeBouncesThenSwaps() {
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
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p2")), onto: .paneEdge(PaneID(rawValue: "w1:p1"), .left), model: sameTabModel)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p2"), workspace: WorkspaceID(rawValue: "w1"), label: nil),
            .movePaneToTab(PaneID(rawValue: "w1:p2"), tab: TabID(rawValue: "w1:t1"), target: PaneID(rawValue: "w1:p1"), split: .right, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
            .swapPanes(PaneID(rawValue: "w1:p2"), PaneID(rawValue: "w1:p1")),
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

    /// Where the pane already is. herdr refuses a same-tab `pane.move`, so a
    /// plan here would reach the user as a rejection rather than springing
    /// back: it comes up whenever a grid drag is released over the thumbnail
    /// it started in.
    func testAPaneDroppedOnItsOwnTabsThumbnailIsANoOp() {
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .tabThumbnail(TabID(rawValue: "w1:t1")), model: twoTabModel())
        switch result {
        case .failure(.noOp): break
        default: XCTFail("expected .noOp, got \(result)")
        }
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

    /// A pane dropped on its own edge must not enter the same-tab bounce:
    /// the bounce's second op would target the dragged pane itself after it
    /// already moved to the temp tab, failing at execution rather than
    /// being a no-op.
    func testDropOnOwnEdgeIsNoOp() {
        let model = twoTabModel()
        for edge: Edge in [.left, .right, .top, .bottom] {
            let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .paneEdge(PaneID(rawValue: "w1:p1"), edge), model: model)
            switch result {
            case .failure(.noOp): break
            default: XCTFail("expected .noOp for edge \(edge), got \(result)")
            }
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

    /// A migration is composed of pane moves, so the destination tab is one
    /// the plan creates. The name the user gave the source tab has to be
    /// asked for by that first op, or the new tab is born unnamed.
    func testTabMigrationCarriesTheSourceTabsName() {
        let named = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1", label: "Deploy logs")],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true)],
            layouts: [layout(
                workspace: "w1", tab: "w1:t1", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 80, 24), focused: true)]
            )]
        )
        let result = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: named)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: "Deploy logs"),
        ])
    }

    /// herdr labels an unrenamed tab with its own 1-based position, so that
    /// string is a default and not a name. Sending it as the new tab's label
    /// would pin the source position as a real name, and the destination can
    /// already hold a tab sitting at that position. The rule is the position,
    /// never `number`: this tab sits first but is numbered 5.
    func testTabMigrationDoesNotCarryAnUnnamedTabsPosition() {
        let unnamed = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t5"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t5", workspace: "w1", number: 5, label: "1")],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t5", focused: true)],
            layouts: [layout(
                workspace: "w1", tab: "w1:t5", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 80, 24), focused: true)]
            )]
        )
        let result = plan(dragging: .tab(TabID(rawValue: "w1:t5")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: unnamed)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [
            .movePaneToNewTab(PaneID(rawValue: "w1:p1"), workspace: WorkspaceID(rawValue: "w2"), label: nil),
        ])
    }

    /// Dropping a tab on the card or rail row of the workspace it is already
    /// in. Migrating would tear the tab down and rebuild it in a new tab of
    /// the same workspace, losing its id for no move at all.
    func testATabDroppedOnItsOwnWorkspaceIsANoOp() {
        let result = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w1")), model: twoTabModel())
        switch result {
        case .failure(.noOp): break
        default: XCTFail("expected .noOp, got \(result)")
        }
    }

    /// A migration whose split list has no split rect exactly matching the
    /// tab's own area cannot resolve a root, so the plan must fail rather
    /// than guess at one (e.g. via a largest-area heuristic).
    func testTabMigrationWithUnresolvableRootIsInvalidCombination() {
        let model = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1")],
            tabs: [tabRecord("w1:t1", workspace: "w1", paneCount: 2)],
            panes: [paneRecord("w1:p1", workspace: "w1", tab: "w1:t1", focused: true), paneRecord("w1:p2", workspace: "w1", tab: "w1:t1")],
            layouts: [layout(
                workspace: "w1", tab: "w1:t1", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 40, 24), focused: true), paneRect("w1:p2", rect(40, 0, 40, 24))],
                // Deliberately mismatched: no split rect equals the tab's own area.
                splits: [splitInfo("s1", .right, 0.5, rect(0, 0, 79, 24))]
            )]
        )
        let result = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), model: model)
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
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

    /// Both gaps either side of a tab's own slot name the place it already
    /// has, so a drop there changes nothing and must not reach herdr. The
    /// preview slides nothing at those gaps for the same reason, from the
    /// same rule.
    func testATabDroppedInItsOwnGapPlansNothing() {
        let model = twoTabModel()
        let workspace = WorkspaceID(rawValue: "w1")
        for insertIndex in [1, 2] {
            guard case .failure(.noOp) = plan(dragging: .tab(TabID(rawValue: "w1:t2")), onto: .tabStrip(workspace: workspace, insertIndex: insertIndex), model: model) else {
                return XCTFail("gap \(insertIndex) is w1:t2's own place")
            }
        }
        for insertIndex in [0, 1] {
            guard case .failure(.noOp) = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .tabStrip(workspace: workspace, insertIndex: insertIndex), model: model) else {
                return XCTFail("gap \(insertIndex) is w1:t1's own place")
            }
        }
        guard case .success = plan(dragging: .tab(TabID(rawValue: "w1:t1")), onto: .tabStrip(workspace: workspace, insertIndex: 2), model: model) else {
            return XCTFail("one slot over still moves")
        }
    }

    func testATabThatIsNotInTheWorkspaceItIsReorderedInIsRefused() {
        guard case .failure(.invalidCombination) = plan(
            dragging: .tab(TabID(rawValue: "w1:t2")), onto: .tabStrip(workspace: WorkspaceID(rawValue: "w2"), insertIndex: 0),
            model: twoTabModel()
        ) else {
            return XCTFail("a tab can only be reordered inside the workspace holding it")
        }
    }

    func testWorkspaceToRailMovesWorkspace() {
        let model = twoTabModel()
        let result = plan(dragging: .workspace(WorkspaceID(rawValue: "w2")), onto: .workspaceRail(insertIndex: 0), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveWorkspace(WorkspaceID(rawValue: "w2"), insertIndex: 0)])
    }

    /// The rail's slot counts only regular rows; herdr's index counts herds
    /// too, so a slot after the first regular row lands after it in herdr.
    func testARailSlotSkipsTheHerdsHerdrListsBetweenRegularWorkspaces() {
        var herd = workspaceRecord("w2", activeTab: "w2:t1")
        herd.label = "herd: review-shapes"
        let model = model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), herd, workspaceRecord("w3", activeTab: "w3:t1"), workspaceRecord("w4", activeTab: "w4:t1")],
            tabs: [], panes: [], layouts: []
        )
        let result = plan(dragging: .workspace(WorkspaceID(rawValue: "w4")), onto: .workspaceRail(insertIndex: 1), model: model)
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveWorkspace(WorkspaceID(rawValue: "w4"), insertIndex: 2)])
    }

    // MARK: - Workspace block -> rail

    private func threeWorkspaceModel() -> SessionModel {
        model(
            workspaces: [workspaceRecord("w1", activeTab: "w1:t1"), workspaceRecord("w2", activeTab: "w2:t1"), workspaceRecord("w3", activeTab: "w3:t1")],
            tabs: [], panes: [], layouts: []
        )
    }

    func testBlockOfFirstAndLastDroppedBeforeTheMiddleIsOneMoveBlock() {
        let result = plan(
            dragging: .workspaces([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3")]),
            onto: .workspaceRail(insertIndex: 1), model: threeWorkspaceModel()
        )
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveWorkspaceBlock([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3")], before: WorkspaceID(rawValue: "w2"))])
        XCTAssertEqual(opPlan.needsUnzoom, [])
    }

    func testBlockIsSentInRailOrderWhateverOrderTheSelectionCameIn() {
        let result = plan(
            dragging: .workspaces([WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w1")]),
            onto: .workspaceRail(insertIndex: 1), model: threeWorkspaceModel()
        )
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveWorkspaceBlock([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3")], before: WorkspaceID(rawValue: "w2"))])
    }

    func testBlockDroppedPastEveryUnmovedWorkspaceHasNoAnchor() {
        let result = plan(
            dragging: .workspaces([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w2")]),
            onto: .workspaceRail(insertIndex: 3), model: threeWorkspaceModel()
        )
        guard let opPlan = expectPlan(result) else { return }
        XCTAssertEqual(opPlan.ops, [.moveWorkspaceBlock([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w2")], before: nil)])
    }

    func testBlockDroppedIntoItsOwnGapIsANoOp() {
        let result = plan(
            dragging: .workspaces([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w2")]),
            onto: .workspaceRail(insertIndex: 1), model: threeWorkspaceModel()
        )
        switch result {
        case .failure(.noOp): break
        default: XCTFail("expected .noOp, got \(result)")
        }
    }

    func testBlockNamingAWorkspaceTheModelLacksIsInvalid() {
        let result = plan(
            dragging: .workspaces([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w9")]),
            onto: .workspaceRail(insertIndex: 3), model: threeWorkspaceModel()
        )
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
    }

    func testBlockOntoTabStripIsInvalidCombination() {
        let result = plan(
            dragging: .workspaces([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3")]),
            onto: .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0), model: threeWorkspaceModel()
        )
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
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

    /// Pane-subject drops name a destination tab/workspace/tab id directly
    /// (unlike tab/workspace-subject drops, which look theirs up from the
    /// model), so each must validate that destination exists too, not just
    /// the subject pane.
    func testPaneToNonexistentTabThumbnailIsInvalidCombination() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .tabThumbnail(TabID(rawValue: "nonexistent")), model: model)
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
    }

    func testPaneToNonexistentWorkspaceThumbnailIsInvalidCombination() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .workspaceThumbnail(WorkspaceID(rawValue: "nonexistent")), model: model)
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
    }

    func testPaneToNonexistentNewTabWorkspaceIsInvalidCombination() {
        let model = twoTabModel()
        let result = plan(dragging: .pane(PaneID(rawValue: "w1:p1")), onto: .newTab(WorkspaceID(rawValue: "nonexistent")), model: model)
        switch result {
        case .failure(.invalidCombination): break
        default: XCTFail("expected .invalidCombination, got \(result)")
        }
    }

    // MARK: - Every target the resolver can produce has a plan

    /// The standing invariant between the two pure layers: a subject that
    /// reaches a surface with no verb for it must resolve to `nil` and spring
    /// back silently, never to a target that then fails planning and reaches
    /// the user as "Can't move there".
    ///
    /// The pair set is SWEPT out of `resolveDropTarget` rather than listed
    /// here, so a future resolver that starts producing a new pair fails this
    /// without anyone remembering to add it.
    func testEveryPairTheResolverCanProduceHasAPlan() {
        let model = twoTabModel()
        let subjects: [DragSubject] = [
            .pane(PaneID(rawValue: "w1:p1")),
            .tab(TabID(rawValue: "w1:t1")),
            .workspace(WorkspaceID(rawValue: "w1")),
            .workspaces([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w2")])
        ]

        var produced: [(DragSubject, DropTarget)] = []
        for surfaces in everySurface() {
            for subject in subjects {
                for x in stride(from: -230.0, through: 680.0, by: 10.0) {
                    for y in stride(from: -10.0, through: 650.0, by: 10.0) {
                        guard let target = resolveDropTarget(at: CGPoint(x: x, y: y), dragging: subject, surfaces: surfaces) else { continue }
                        guard !produced.contains(where: { $0.0 == subject && $0.1 == target }) else { continue }
                        produced.append((subject, target))
                    }
                }
            }
        }

        // Guards against a sweep that silently covers nothing: every one of
        // the resolver's nine target cases is reachable from these surfaces.
        XCTAssertEqual(Set(produced.map { Self.caseName($0.1) }).count, 9, "\(Set(produced.map { Self.caseName($0.1) }))")

        for (subject, target) in produced {
            if case .failure(.invalidCombination) = plan(dragging: subject, onto: target, model: model) {
                XCTFail("resolver produces \(subject) onto \(target), which GesturePlanner has no case for")
            }
        }
    }

    private static func caseName(_ target: DropTarget) -> String {
        switch target {
        case .paneEdge: "paneEdge"
        case .paneInterior: "paneInterior"
        case .tabStrip: "tabStrip"
        case .tabThumbnail: "tabThumbnail"
        case .workspaceThumbnail: "workspaceThumbnail"
        case .newTab: "newTab"
        case .newWorkspace: "newWorkspace"
        case .workspaceRail: "workspaceRail"
        case .moreTabs: "moreTabs"
        }
    }

    /// The window with its free runs, and the grid covering it with one card
    /// per workspace, so the sweep reaches every tier.
    private func everySurface() -> [DropSurfaces] {
        let window = windowSurface()
        let grid = DropSurfaces(
            canvas: window.canvas, stripWorkspace: window.stripWorkspace, tabFrames: window.tabFrames,
            workspaceFrames: window.workspaceFrames, stripFrame: window.stripFrame, railFrame: window.railFrame,
            newTabZone: window.newTabZone, newWorkspaceZone: window.newWorkspaceZone,
            grid: GridDropSurfaces(
                viewport: CGRect(x: 0, y: 0, width: 600, height: 600),
                thumbnails: [TabItemFrame(id: TabID(rawValue: "w1:t2"), frame: CGRect(x: 10, y: 10, width: 100, height: 82))],
                tiles: [WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 120, y: 10, width: 100, height: 82))],
                cards: [
                    WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 0, y: 0, width: 240, height: 120)),
                    WorkspaceItemFrame(id: WorkspaceID(rawValue: "w2"), frame: CGRect(x: 260, y: 0, width: 240, height: 120)),
                ]
            )
        )
        return [window, grid]
    }

    /// Canvas, strip, rail and both free runs at once, with ids the model
    /// knows.
    private func windowSurface() -> DropSurfaces {
        let canvas = CanvasGeometry(
            layout: layout(
                workspace: "w1", tab: "w1:t1", area: rect(0, 0, 80, 24), focusedPane: "w1:p1",
                panes: [paneRect("w1:p1", rect(0, 0, 40, 24), focused: true), paneRect("w1:p2", rect(40, 0, 40, 24))]
            ),
            grid: CanvasGrid(canvas: CGSize(width: 600, height: 300))
        )
        let stripFrame = CGRect(x: 0, y: 300, width: 600, height: 40)
        let railFrame = CGRect(x: -216, y: 0, width: 216, height: 600)
        return DropSurfaces(
            canvas: canvas,
            stripWorkspace: WorkspaceID(rawValue: "w1"),
            tabFrames: [
                TabItemFrame(id: TabID(rawValue: "w1:t1"), frame: CGRect(x: 12, y: 306, width: 100, height: 28)),
                TabItemFrame(id: TabID(rawValue: "w1:t2"), frame: CGRect(x: 122, y: 306, width: 100, height: 28))
            ],
            workspaceFrames: [
                WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: -208, y: 40, width: 200, height: 30)),
                WorkspaceItemFrame(id: WorkspaceID(rawValue: "w2"), frame: CGRect(x: -208, y: 72, width: 200, height: 30))
            ],
            stripFrame: stripFrame,
            railFrame: railFrame,
            newTabZone: DropZones.trailing(in: stripFrame, itemsEndingAt: 222, before: 520),
            newWorkspaceZone: DropZones.below(in: railFrame, itemsEndingAt: 102)
        )
    }
}
