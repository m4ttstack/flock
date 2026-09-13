import XCTest
@testable import PaddockCore

final class MoveToMenuTests: XCTestCase {
    // MARK: - Fixture (mirrors GesturePlannerTests' pattern)

    private func paneRecord(_ id: String, workspace: String, tab: String) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab),
            focused: false, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
    }

    private func tabRecord(_ id: String, workspace: String, label: String) -> TabRecord {
        TabRecord(tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), label: label, number: 1, paneCount: 1, agentStatus: .idle)
    }

    private func workspaceRecord(_ id: String, activeTab: String, label: String) -> WorkspaceRecord {
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: id), label: label, number: 1, activeTabID: TabID(rawValue: activeTab), agentStatus: .idle)
    }

    /// The canonical fixture: w1 has two tabs (t1 holding the pane under
    /// test plus t2), w2 is a second, empty workspace.
    private func canonicalFixture() -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [
                workspaceRecord("w1", activeTab: "w1:t1", label: "one"),
                workspaceRecord("w2", activeTab: "w2:t1", label: "two"),
            ],
            tabs: [
                tabRecord("w1:t1", workspace: "w1", label: "first"),
                tabRecord("w1:t2", workspace: "w1", label: "second"),
                tabRecord("w2:t1", workspace: "w2", label: "third"),
            ],
            panes: [
                paneRecord("w1:p1", workspace: "w1", tab: "w1:t1"),
                paneRecord("w1:p2", workspace: "w1", tab: "w1:t1"),
                paneRecord("w1:p3", workspace: "w1", tab: "w1:t2"),
            ],
            layouts: []
        ))
    }

    func testEntriesListsOtherTabsThenOtherWorkspacesThenTheTwoNewItems() {
        let entries = MoveToMenu.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture())

        XCTAssertEqual(entries.map(\.label), ["Tab: second", "Workspace: two", "New Tab", "New Workspace"])
        XCTAssertEqual(entries.map(\.target), [
            .tabThumbnail(TabID(rawValue: "w1:t2")),
            .workspaceThumbnail(WorkspaceID(rawValue: "w2")),
            .newTab(WorkspaceID(rawValue: "w1")),
            .newWorkspace,
        ])
    }

    func testEntriesExcludesThePanesOwnTab() {
        let entries = MoveToMenu.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture())

        XCTAssertFalse(entries.contains { $0.target == .tabThumbnail(TabID(rawValue: "w1:t1")) })
    }

    func testEntriesEmptyWhenPaneIsNotInTheModel() {
        let entries = MoveToMenu.entries(for: PaneID(rawValue: "ghost"), model: canonicalFixture())

        XCTAssertEqual(entries, [])
    }

    func testSwapTargetIsPaneInteriorOfTheFocusedPaneWhenSameTabAndNotFocused() {
        let target = MoveToMenu.swapTarget(for: PaneID(rawValue: "w1:p1"), focusedPane: PaneID(rawValue: "w1:p2"), model: canonicalFixture())

        XCTAssertEqual(target, .paneInterior(PaneID(rawValue: "w1:p2")))
    }

    func testSwapTargetIsNilWhenThePaneIsTheFocusedPane() {
        let target = MoveToMenu.swapTarget(for: PaneID(rawValue: "w1:p1"), focusedPane: PaneID(rawValue: "w1:p1"), model: canonicalFixture())

        XCTAssertNil(target)
    }

    func testSwapTargetIsNilWhenNothingIsFocused() {
        let target = MoveToMenu.swapTarget(for: PaneID(rawValue: "w1:p1"), focusedPane: nil, model: canonicalFixture())

        XCTAssertNil(target)
    }

    /// `resolvedFocusedPaneID` is herdr's GLOBAL focus, not scoped to this
    /// pane's own tab -- a focused pane in a DIFFERENT tab must not offer a
    /// swap (that would plan a cross-tab MOVE under a "Swap" label).
    func testSwapTargetIsNilWhenTheFocusedPaneIsInADifferentTab() {
        let target = MoveToMenu.swapTarget(for: PaneID(rawValue: "w1:p1"), focusedPane: PaneID(rawValue: "w1:p3"), model: canonicalFixture())

        XCTAssertNil(target)
    }
}
