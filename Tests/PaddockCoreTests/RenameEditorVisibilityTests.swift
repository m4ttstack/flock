import XCTest
@testable import PaddockCore

/// Which rename editors the window is actually drawing. A pane's terminal
/// yields the keyboard to an editor on screen and must not yield to one that
/// only still EXISTS, which is every editor whose workspace or tab herdr has
/// since focused away from.
final class RenameEditorVisibilityTests: XCTestCase {
    private func model() -> SessionModel {
        func pane(_ id: String, workspace: String, tab: String) -> PaneRecord {
            PaneRecord(
                paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace),
                tabID: TabID(rawValue: tab), focused: false, agentStatus: .idle, revision: 0,
                terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
            )
        }
        func tab(_ id: String, workspace: String) -> TabRecord {
            TabRecord(
                tabID: TabID(rawValue: id), workspaceID: WorkspaceID(rawValue: workspace), label: id,
                number: 1, paneCount: 1, agentStatus: .idle
            )
        }
        func workspace(_ id: String, activeTab: String) -> WorkspaceRecord {
            WorkspaceRecord(
                workspaceID: WorkspaceID(rawValue: id), label: id, number: 1,
                activeTabID: TabID(rawValue: activeTab), agentStatus: .idle
            )
        }
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [workspace("w1", activeTab: "w1:t1"), workspace("w2", activeTab: "w2:t1")],
            tabs: [tab("w1:t1", workspace: "w1"), tab("w1:t2", workspace: "w1"), tab("w2:t1", workspace: "w2")],
            panes: [
                pane("w1:p1", workspace: "w1", tab: "w1:t1"),
                pane("w1:p2", workspace: "w1", tab: "w1:t2"),
                pane("w2:p1", workspace: "w2", tab: "w2:t1"),
            ],
            layouts: []
        ))
    }

    private func isOnScreen(_ target: RenameTarget?, workspace: String? = "w1", tab: String? = "w1:t1") -> Bool {
        RenameEditor.isOnScreen(
            target,
            selectedWorkspace: workspace.map { WorkspaceID(rawValue: $0) },
            selectedTab: tab.map { TabID(rawValue: $0) },
            model: model()
        )
    }

    func testNoTargetIsNoEditor() {
        XCTAssertFalse(isOnScreen(nil))
    }

    func testAPanesEditorIsDrawnOnlyForThePanesOfTheSelectedTab() {
        XCTAssertTrue(isOnScreen(.pane(PaneID(rawValue: "w1:p1"))))
        XCTAssertFalse(
            isOnScreen(.pane(PaneID(rawValue: "w1:p2"))),
            "the canvas draws one tab's panes, so a pane of another tab has no editor on screen"
        )
        XCTAssertFalse(isOnScreen(.pane(PaneID(rawValue: "w2:p1"))))
    }

    func testATabsEditorIsDrawnOnlyForTheTabsOfTheSelectedWorkspace() {
        XCTAssertTrue(isOnScreen(.tab(TabID(rawValue: "w1:t1"))))
        XCTAssertTrue(
            isOnScreen(.tab(TabID(rawValue: "w1:t2"))),
            "the strip draws every tab of the selected workspace, selected or not"
        )
        XCTAssertFalse(
            isOnScreen(.tab(TabID(rawValue: "w2:t1"))),
            "a tab of another workspace is not in the strip, so its editor is not on screen"
        )
    }

    /// The case the keyboard was stranded by: herdr focuses another workspace
    /// while a tab's editor is open, the view goes, and the target stays.
    func testATabsEditorStopsBeingOnScreenWhenTheWorkspaceIsFocusedAway() {
        let target = RenameTarget.tab(TabID(rawValue: "w1:t1"))
        XCTAssertTrue(isOnScreen(target))
        XCTAssertFalse(isOnScreen(target, workspace: "w2", tab: "w2:t1"))
    }

    /// The rail draws every workspace there is, so this one is on screen for
    /// as long as it exists, whatever herdr is focused on.
    func testAWorkspacesEditorIsDrawnWhicheverWorkspaceIsSelected() {
        let target = RenameTarget.workspace(WorkspaceID(rawValue: "w1"))
        XCTAssertTrue(isOnScreen(target))
        XCTAssertTrue(isOnScreen(target, workspace: "w2", tab: "w2:t1"))
    }

    /// A target the model no longer carries is not on screen either, however
    /// the selection stands: the editor closes on that separately, and a rule
    /// that answered yes here would hold the keyboard for a tab that is gone.
    func testATargetTheModelNoLongerCarriesIsNotOnScreen() {
        XCTAssertFalse(isOnScreen(.tab(TabID(rawValue: "w1:t9"))))
        XCTAssertFalse(isOnScreen(.pane(PaneID(rawValue: "w1:p9"))))
        XCTAssertFalse(isOnScreen(.workspace(WorkspaceID(rawValue: "w9"))))
    }

    func testNothingIsOnScreenWithoutAModelOrASelection() {
        XCTAssertFalse(RenameEditor.isOnScreen(
            .tab(TabID(rawValue: "w1:t1")), selectedWorkspace: WorkspaceID(rawValue: "w1"),
            selectedTab: TabID(rawValue: "w1:t1"), model: nil
        ))
        XCTAssertFalse(isOnScreen(.tab(TabID(rawValue: "w1:t1")), workspace: nil))
        XCTAssertFalse(isOnScreen(.pane(PaneID(rawValue: "w1:p1")), tab: nil))
    }
}
