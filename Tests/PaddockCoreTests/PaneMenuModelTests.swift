import XCTest
@testable import PaddockCore

final class PaneMenuModelTests: XCTestCase {
    // MARK: - Fixture (mirrors MoveToMenuTests' pattern)

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

    /// w1 has two tabs (t1 holding p1 and p2, plus t2 holding p3); w2 is a
    /// second, empty workspace.
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

    // MARK: - Order and identifiers

    func testEntriesOrderWithNoFocusedPane() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: nil)

        XCTAssertEqual(entries.map(\.label), ["Split Right", "Split Down", "Move to...", "Close Pane"])
        XCTAssertEqual(entries.map(\.accessibilityIdentifier), [
            "paddock.pane.menu.splitRight",
            "paddock.pane.menu.splitDown",
            "paddock.pane.menu.moveTo",
            "paddock.pane.menu.closePane",
        ])
    }

    func testEntriesOrderWithSwapLeadsWhenAnotherPaneInTheSameTabIsFocused() {
        let entries = PaneMenuModel.entries(for: PaneID(rawValue: "w1:p1"), model: canonicalFixture(), focusedPane: PaneID(rawValue: "w1:p2"))

        XCTAssertEqual(entries.map(\.label), ["Swap with Focused Pane", "Split Right", "Split Down", "Move to...", "Close Pane"])
        XCTAssertEqual(entries.first?.accessibilityIdentifier, "paddock.pane.menu.swap")
        XCTAssertEqual(entries.first?.action, .swapWithFocused(PaneID(rawValue: "w1:p2")))
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
