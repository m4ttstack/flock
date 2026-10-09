import XCTest
@testable import FlockCore

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

    func testAnUnnamedOnePaneTabIsListedByItsPanesTitle() {
        var model = canonicalFixture()
        model.tabs[WorkspaceID(rawValue: "w1")]?[1].label = "2"
        model.panes[PaneID(rawValue: "w1:p3")] = PaneRecord(
            paneID: PaneID(rawValue: "w1:p3"), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t2"),
            focused: false, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: "release", cwd: "/tmp", scroll: nil
        )

        let entries = MoveToMenu.entries(for: PaneID(rawValue: "w1:p1"), model: model)

        XCTAssertEqual(entries.first?.label, "release")
    }

    func testEntriesListsOtherTabsThenOtherWorkspacesThenTheTwoNewItems() {
        let entries = MoveToMenu.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture())

        XCTAssertEqual(entries.map(\.label), ["second", "two", "New Tab", "New Workspace"])
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

    /// w2 is pinned as "pinned two", and "notes" is a pin with nothing open.
    private func pinnedSections(_ model: SessionModel) -> RailSections {
        RailSections(model: model, board: nil, pins: [
            PinnedWorkspace(id: PinID(rawValue: "a"), name: "pinned two", folder: "/acme", workspace: WorkspaceID(rawValue: "w2"), syncedLabel: "two", confirmed: true),
            PinnedWorkspace(id: PinID(rawValue: "b"), name: "notes", folder: "/acme", workspace: nil, syncedLabel: nil, confirmed: false),
        ])
    }

    func testWithTheRailTheWorkspacesFollowItsPinsAndAnEmptyPinIsATarget() {
        let model = canonicalFixture()
        let entries = MoveToMenu.entries(for: PaneID(rawValue: "w1:p1"), model: model, sections: pinnedSections(model))
        let workspaces = entries.filter { $0.group == .workspaces }

        XCTAssertEqual(workspaces.map(\.label), ["pinned two", "notes"])
        XCTAssertEqual(workspaces.map(\.target), [.workspaceThumbnail(WorkspaceID(rawValue: "w2")), .emptyPin(PinID(rawValue: "b"))])
        XCTAssertEqual(workspaces.map(\.identityKey), ["pin:a", "pin:b"])
    }

    func testTheMenuGroupsTabsAndWorkspacesUnderHeadersAndSetsTheCreateRowsApart() throws {
        let model = canonicalFixture()
        let entries = PaneMenuModel.entries(
            for: PaneID(rawValue: "w1:p1"), model: model, focusedPane: nil, sections: pinnedSections(model)
        )
        let submenu = try XCTUnwrap(entries.first { $0.accessibilityIdentifier == "flock.pane.menu.moveTo" }?.submenu)

        XCTAssertEqual(submenu.map(\.role), [.header, .item, .header, .item, .item, .separator, .item, .item])
        XCTAssertEqual(submenu.map(\.label), ["Tabs", "second", "Workspaces", "pinned two", "notes", "", "New Tab", "New Workspace"])
        XCTAssertEqual(submenu[4].action, .moveTo(.emptyPin(PinID(rawValue: "b"))))
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
