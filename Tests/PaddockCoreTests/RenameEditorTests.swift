import XCTest
@testable import PaddockCore

final class RenameEditorTests: XCTestCase {
    private static let pane = PaneID(rawValue: "w1:p1")
    private static let unlabelledPane = PaneID(rawValue: "w1:p2")
    private static let tab = TabID(rawValue: "w1:t1")
    private static let workspace = WorkspaceID(rawValue: "w1")

    /// `w1:p1` carries a manual label, `w1:p2` none; the tab is "first" and
    /// the workspace "one".
    private func model() -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [WorkspaceRecord(
                workspaceID: Self.workspace, label: "one", number: 1, activeTabID: Self.tab, agentStatus: .idle
            )],
            tabs: [TabRecord(
                tabID: Self.tab, workspaceID: Self.workspace, label: "first", number: 1, paneCount: 2, agentStatus: .idle
            )],
            panes: [
                PaneRecord(
                    paneID: Self.pane, workspaceID: Self.workspace, tabID: Self.tab, focused: true, agentStatus: .idle,
                    revision: 0, terminalTitleStripped: "zsh", label: "build", cwd: "/tmp", scroll: nil
                ),
                PaneRecord(
                    paneID: Self.unlabelledPane, workspaceID: Self.workspace, tabID: Self.tab, focused: false, agentStatus: .idle,
                    revision: 0, terminalTitleStripped: "zsh", label: nil, cwd: "/tmp", scroll: nil
                ),
            ],
            layouts: []
        ))
    }

    // MARK: - Initial text

    func testAPaneOpensOnItsManualLabelAndNeverOnItsTerminalTitle() {
        XCTAssertEqual(RenameEditor.initialText(for: .pane(Self.pane), model: model()), "build")
        XCTAssertEqual(RenameEditor.initialText(for: .pane(Self.unlabelledPane), model: model()), "")
    }

    func testATabAndAWorkspaceOpenOnTheirOwnLabels() {
        XCTAssertEqual(RenameEditor.initialText(for: .tab(Self.tab), model: model()), "first")
        XCTAssertEqual(RenameEditor.initialText(for: .workspace(Self.workspace), model: model()), "one")
    }

    func testAnEditorOnAnAbsentTargetOrNoModelOpensEmpty() {
        XCTAssertEqual(RenameEditor.initialText(for: .pane(PaneID(rawValue: "ghost")), model: model()), "")
        XCTAssertEqual(RenameEditor.initialText(for: .tab(Self.tab), model: nil), "")
    }

    // MARK: - Commit: trimmed, non-empty, changed

    func testACommitTrimsSurroundingWhitespaceBeforeIssuingTheRename() {
        XCTAssertEqual(
            RenameEditor.commit("  api  ", for: .pane(Self.pane), model: model()),
            .renamePane(Self.pane, "api")
        )
        XCTAssertEqual(
            RenameEditor.commit("\n api \n", for: .tab(Self.tab), model: model()),
            .renameTab(Self.tab, "api")
        )
        XCTAssertEqual(
            RenameEditor.commit(" api", for: .workspace(Self.workspace), model: model()),
            .renameWorkspace(Self.workspace, "api")
        )
    }

    func testACommitOfBlankTextIssuesNothingAtAnyLevel() {
        for text in ["", "   ", "\n", " \t "] {
            XCTAssertNil(RenameEditor.commit(text, for: .pane(Self.pane), model: model()), text.debugDescription)
            XCTAssertNil(RenameEditor.commit(text, for: .tab(Self.tab), model: model()), text.debugDescription)
            XCTAssertNil(RenameEditor.commit(text, for: .workspace(Self.workspace), model: model()), text.debugDescription)
        }
    }

    /// A blank pane commit must not be read as "clear the name": clearing is
    /// its own menu command, and `pane.rename` with a null label is what it
    /// sends.
    func testABlankPaneCommitDoesNotClearTheManualLabel() {
        XCTAssertNotEqual(RenameEditor.commit("  ", for: .pane(Self.pane), model: model()), .renamePane(Self.pane, nil))
        XCTAssertNil(RenameEditor.commit("  ", for: .pane(Self.pane), model: model()))
    }

    func testACommitOfTheLabelAlreadyShowingIssuesNothing() {
        XCTAssertNil(RenameEditor.commit("build", for: .pane(Self.pane), model: model()))
        XCTAssertNil(RenameEditor.commit(" build ", for: .pane(Self.pane), model: model()), "trimmed to the same label")
        XCTAssertNil(RenameEditor.commit("first", for: .tab(Self.tab), model: model()))
        XCTAssertNil(RenameEditor.commit("one", for: .workspace(Self.workspace), model: model()))
    }

    func testAFirstLabelOnAPaneThatHadNoneIsARealChange() {
        XCTAssertEqual(
            RenameEditor.commit("api", for: .pane(Self.unlabelledPane), model: model()),
            .renamePane(Self.unlabelledPane, "api")
        )
    }

    func testACommitAgainstAnAbsentTargetOrNoModelIssuesNothing() {
        XCTAssertNil(RenameEditor.commit("api", for: .pane(PaneID(rawValue: "ghost")), model: model()))
        XCTAssertNil(RenameEditor.commit("api", for: .tab(TabID(rawValue: "ghost")), model: model()))
        XCTAssertNil(RenameEditor.commit("api", for: .workspace(WorkspaceID(rawValue: "ghost")), model: model()))
        XCTAssertNil(RenameEditor.commit("api", for: .tab(Self.tab), model: nil))
    }

    // MARK: - Existence (what closes an open editor)

    func testATargetTheModelCarriesExistsAtEveryLevel() {
        XCTAssertTrue(RenameTarget.pane(Self.pane).exists(in: model()))
        XCTAssertTrue(RenameTarget.tab(Self.tab).exists(in: model()))
        XCTAssertTrue(RenameTarget.workspace(Self.workspace).exists(in: model()))
    }

    func testATargetTheModelHasLostDoesNotExistAtAnyLevel() {
        XCTAssertFalse(RenameTarget.pane(PaneID(rawValue: "ghost")).exists(in: model()))
        XCTAssertFalse(RenameTarget.tab(TabID(rawValue: "ghost")).exists(in: model()))
        XCTAssertFalse(RenameTarget.workspace(WorkspaceID(rawValue: "ghost")).exists(in: model()))
    }

    func testEachLevelCarriesItsOwnUndoLabel() {
        XCTAssertEqual(RenameEditor.planLabel(for: .pane(Self.pane)), "Rename pane")
        XCTAssertEqual(RenameEditor.planLabel(for: .tab(Self.tab)), "Rename tab")
        XCTAssertEqual(RenameEditor.planLabel(for: .workspace(Self.workspace)), "Rename workspace")
    }
}
