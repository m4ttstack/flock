import XCTest
@testable import PaddockCore

final class PaneMenuModelTests: XCTestCase {
    // MARK: - Fixture (mirrors MoveToMenuTests' pattern)

    private func paneRecord(_ id: String, workspace: String, tab: String, label: String? = nil) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), tabID: TabID(rawValue: tab),
            focused: false, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: label, cwd: "/tmp", scroll: nil
        )
    }

    private func tabRecord(_ id: String, workspace: String, label: String) -> TabRecord {
        TabRecord(tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), label: label, number: 1, paneCount: 1, agentStatus: .idle)
    }

    private func workspaceRecord(_ id: String, activeTab: String, label: String) -> WorkspaceRecord {
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: id), label: label, number: 1, activeTabID: TabID(rawValue: activeTab), agentStatus: .idle)
    }

    /// w1 has two tabs (t1 holding p1, p2 and the manually-labelled p4, plus
    /// t2 holding p3); w2 is a second, empty workspace.
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
                paneRecord("w1:p4", workspace: "w1", tab: "w1:t1", label: "build"),
            ],
            layouts: []
        ))
    }

    // MARK: - Order and identifiers

    func testEntriesOrderWithNoFocusedPane() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)

        XCTAssertEqual(entries.map(\.label), ["Rename Pane", "Split Right", "Split Down", "Zoom", "Move to...", "Close Pane"])
        XCTAssertEqual(entries.map(\.accessibilityIdentifier), [
            "paddock.pane.menu.rename",
            "paddock.pane.menu.splitRight",
            "paddock.pane.menu.splitDown",
            "paddock.pane.menu.zoom",
            "paddock.pane.menu.moveTo",
            "paddock.pane.menu.closePane",
        ])
    }

    func testEntriesOrderWithSwapBetweenRenameAndTheSplitsWhenAnotherPaneInTheSameTabIsFocused() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: PaneID(rawValue: "w1:p2"))

        XCTAssertEqual(
            entries.map(\.label),
            ["Rename Pane", "Swap with Focused Pane", "Split Right", "Split Down", "Zoom", "Move to...", "Close Pane"]
        )
        XCTAssertEqual(entries[1].accessibilityIdentifier, "paddock.pane.menu.swap")
        XCTAssertEqual(entries[1].action, .swapWithFocused(PaneID(rawValue: "w1:p2")))
    }

    // MARK: - Rename / Clear name / Zoom (the herdr rows)

    func testRenamePaneLeadsEveryMenuAndCarriesItsOwnAction() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)

        XCTAssertEqual(entries.first?.label, "Rename Pane")
        XCTAssertEqual(entries.first?.action, .renamePane)
        XCTAssertEqual(entries.first?.enabled, true)
    }

    /// herdr shows Clear pane name only while the pane carries a manual
    /// label, since there is otherwise nothing to clear.
    func testClearPaneNameAppearsOnlyForAPaneWithAManualLabel() {
        let labelled = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p4"), model: canonicalFixture(), focusedPane: nil)
        let unlabelled = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)

        XCTAssertEqual(labelled.map(\.label).prefix(2), ["Rename Pane", "Clear Pane Name"])
        XCTAssertEqual(labelled[1].accessibilityIdentifier, "paddock.pane.menu.clearName")
        XCTAssertEqual(labelled[1].action, .clearPaneName)
        XCTAssertFalse(unlabelled.contains { $0.action == .clearPaneName })
    }

    func testZoomSitsAfterTheSplitsAsItDoesInHerdr() throws {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)
        let labels = entries.map(\.label)

        XCTAssertEqual(try XCTUnwrap(labels.firstIndex(of: "Zoom")), try XCTUnwrap(labels.firstIndex(of: "Split Down")) + 1)
        XCTAssertEqual(entries.first { $0.label == "Zoom" }?.action, .zoom)
    }

    /// herdr's own right-click passthrough toggle has no paddock equivalent:
    /// the disposition is decided per click, not per pane.
    func testNoRightClickRoutingRowIsOffered() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)

        XCTAssertFalse(entries.contains { $0.label.lowercased().contains("right-click") })
    }

    // MARK: - Swap suppression

    func testNoSwapWhenThePaneItselfIsFocused() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: PaneID(rawValue: "w1:p1"))

        XCTAssertFalse(entries.map(\.label).contains("Swap with Focused Pane"))
        XCTAssertTrue(entries.contains { $0.action == .splitRight })
    }

    func testNoSwapWhenFocusIsInAnotherTab() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: PaneID(rawValue: "w1:p3"))

        XCTAssertFalse(entries.map(\.label).contains("Swap with Focused Pane"))
    }

    // MARK: - Move to submenu mirrors MoveToMenu

    func testMoveToSubmenuMirrorsMoveToMenuEntries() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)
        let moveTo = entries.first { $0.accessibilityIdentifier == "paddock.pane.menu.moveTo" }
        let expected = MoveToMenu.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture())

        XCTAssertEqual(moveTo?.submenu?.map(\.label), expected.map(\.label))
        XCTAssertEqual(moveTo?.submenu?.map(\.accessibilityIdentifier), expected.map(\.accessibilityIdentifier))
        XCTAssertEqual(moveTo?.submenu?.map(\.action), expected.map { .moveTo($0.target) })
        XCTAssertTrue(moveTo?.enabled == true)
    }

    func testMoveToIsDisabledWithAnEmptySubmenuWhenThePaneIsNotInTheModel() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "ghost"), model: canonicalFixture(), focusedPane: nil)
        let moveTo = entries.first { $0.accessibilityIdentifier == "paddock.pane.menu.moveTo" }

        XCTAssertEqual(moveTo?.submenu, [])
        XCTAssertEqual(moveTo?.enabled, false)
    }

    // MARK: - Actions and enabled state

    func testSplitAndCloseAreAlwaysPresentAndEnabled() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "ghost"), model: canonicalFixture(), focusedPane: nil)

        let splitRight = entries.first { $0.accessibilityIdentifier == "paddock.pane.menu.splitRight" }
        let splitDown = entries.first { $0.accessibilityIdentifier == "paddock.pane.menu.splitDown" }
        let close = entries.first { $0.accessibilityIdentifier == "paddock.pane.menu.closePane" }

        XCTAssertEqual(splitRight?.action, .splitRight)
        XCTAssertEqual(splitRight?.enabled, true)
        XCTAssertEqual(splitDown?.action, .splitDown)
        XCTAssertEqual(splitDown?.enabled, true)
        XCTAssertEqual(close?.action, .closePane)
        XCTAssertEqual(close?.enabled, true)
    }

    func testSubmenuParentRowsCarryNoAction() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)
        let moveTo = entries.first { $0.accessibilityIdentifier == "paddock.pane.menu.moveTo" }

        XCTAssertNil(moveTo?.action)
    }
}
