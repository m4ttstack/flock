import XCTest
@testable import FlockCore

@MainActor
final class PaneNamingTests: XCTestCase {
    private typealias W = MissionFixture.Workspace
    private typealias T = MissionFixture.Tab
    private typealias P = MissionFixture.Pane

    /// `w1:t1` "api" holds one pane, `w1:t2` unnamed ("2") holds one, `w1:t3`
    /// "tests" holds two.
    private func model() -> SessionModel {
        MissionFixture.model([W(label: "acme", tabs: [
            T(label: "api", panes: [P(status: .working, title: "Fix refunds")]),
            T(label: "2", panes: [P(status: .idle, title: "Migrate users")]),
            T(label: "tests", panes: [P(status: .working, title: "codex"), P(status: .idle, title: "Tests")]),
        ])])
    }

    private func pane(_ id: String, in model: SessionModel) -> PaneRecord {
        model.panes[PaneID(rawValue: id)]!
    }

    private func edit(_ model: inout SessionModel, _ id: String, label: String? = nil, tab: String? = nil) {
        let old = pane(id, in: model)
        model.panes[old.paneID] = PaneRecord(
            paneID: old.paneID, workspaceID: old.workspaceID, tabID: tab.map(TabID.init(rawValue:)) ?? old.tabID,
            focused: old.focused, agentStatus: old.agentStatus, revision: old.revision,
            terminalTitleStripped: old.terminalTitleStripped, label: label ?? old.label, cwd: old.cwd, scroll: old.scroll
        )
    }

    func testANamedOnePaneTabIsTheOneTitle() {
        let model = model()
        let pane = pane("w1:t1:p1", in: model)
        XCTAssertNil(PaneNaming.shownTitle(pane: pane, model: model, oneTitle: true))
        XCTAssertEqual(PaneNaming.name(pane: pane, model: model, oneTitle: true), "api")
        XCTAssertEqual(PaneNaming.cardTitles(pane: pane, model: model, oneTitle: true), .init(title: "api", detail: nil))
    }

    func testAnUnnamedOnePaneTabBorrowsThePanesTitle() {
        let model = model()
        let pane = pane("w1:t2:p1", in: model)
        XCTAssertNil(PaneNaming.shownTitle(pane: pane, model: model, oneTitle: true))
        XCTAssertEqual(PaneNaming.name(pane: pane, model: model, oneTitle: true), "Migrate users")
        XCTAssertEqual(PaneNaming.cardTitles(pane: pane, model: model, oneTitle: true), .init(title: "Migrate users", detail: nil))
    }

    func testPanesSharingATabKeepTheirOwnTitles() {
        let model = model()
        let codex = pane("w1:t3:p1", in: model)
        XCTAssertEqual(PaneNaming.shownTitle(pane: codex, model: model, oneTitle: true), "codex")
        XCTAssertEqual(PaneNaming.name(pane: codex, model: model, oneTitle: true), "codex")
        XCTAssertEqual(PaneNaming.cardTitles(pane: codex, model: model, oneTitle: true), .init(title: "tests", detail: "codex"))
        let tests = pane("w1:t3:p2", in: model)
        XCTAssertEqual(
            PaneNaming.cardTitles(pane: tests, model: model, oneTitle: true), .init(title: "tests", detail: nil),
            "a pane titled like its tab, ignoring case, adds no second line"
        )
    }

    func testAZoomedTabOfTwoStillNamesBothPanes() {
        var model = model()
        let area = CellRect(x: 0, y: 0, width: 20, height: 10)
        let tab = TabID(rawValue: "w1:t3")
        model.layouts[tab] = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: tab, zoomed: true, area: area,
            focusedPaneID: PaneID(rawValue: "w1:t3:p1"),
            panes: [PaneRect(paneID: PaneID(rawValue: "w1:t3:p1"), focused: true, rect: area)],
            splits: []
        )
        XCTAssertEqual(PaneNaming.shownTitle(pane: pane("w1:t3:p1", in: model), model: model, oneTitle: true), "codex")
    }

    func testOffEveryPaneKeepsItsTitleAndTheTabFollowsOnCards() {
        let model = model()
        let alone = pane("w1:t1:p1", in: model)
        XCTAssertEqual(PaneNaming.shownTitle(pane: alone, model: model, oneTitle: false), "Fix refunds")
        XCTAssertEqual(PaneNaming.name(pane: alone, model: model, oneTitle: false), "Fix refunds")
        XCTAssertEqual(PaneNaming.cardTitles(pane: alone, model: model, oneTitle: false), .init(title: "Fix refunds", detail: "api"))
        let unnamed = pane("w1:t2:p1", in: model)
        XCTAssertEqual(
            PaneNaming.cardTitles(pane: unnamed, model: model, oneTitle: false), .init(title: "Migrate users", detail: nil),
            "a borrowed tab title repeats the pane's"
        )
        XCTAssertEqual(PaneNaming.renameTarget(.pane(alone.paneID), model: model, oneTitle: false), .pane(alone.paneID))
    }

    func testAnUnnamedTabOfTwoNeverLeadsWithItsNumber() {
        let model = MissionFixture.model([W(label: "acme", tabs: [
            T(label: "1", panes: [P(status: .working, title: "codex"), P(status: .idle, title: "zsh")]),
        ])])
        let codex = pane("w1:t1:p1", in: model)
        XCTAssertEqual(PaneNaming.cardTitles(pane: codex, model: model, oneTitle: true), .init(title: "codex", detail: nil))
        XCTAssertEqual(PaneNaming.cardTitles(pane: codex, model: model, oneTitle: false), .init(title: "codex", detail: nil))
    }

    func testAPaneMovedOutOfItsTabChangesWhoIsTitled() {
        var model = model()
        edit(&model, "w1:t3:p2", tab: "w1:t1")
        let left = pane("w1:t3:p1", in: model)
        XCTAssertNil(PaneNaming.shownTitle(pane: left, model: model, oneTitle: true), "the pane left behind is alone now")
        let joined = pane("w1:t1:p1", in: model)
        XCTAssertEqual(PaneNaming.shownTitle(pane: joined, model: model, oneTitle: true), "Fix refunds", "a split tab names its panes again")
    }

    func testRenamingAPaneAloneInItsTabRenamesTheTab() {
        let model = model()
        XCTAssertEqual(
            PaneNaming.renameTarget(.pane(PaneID(rawValue: "w1:t1:p1")), model: model, oneTitle: true), .tab(TabID(rawValue: "w1:t1"))
        )
        XCTAssertEqual(
            PaneNaming.renameTarget(.pane(PaneID(rawValue: "w1:t3:p1")), model: model, oneTitle: true), .pane(PaneID(rawValue: "w1:t3:p1"))
        )
        XCTAssertEqual(
            PaneNaming.renameTarget(.workspace(WorkspaceID(rawValue: "w1")), model: model, oneTitle: true), .workspace(WorkspaceID(rawValue: "w1"))
        )
        XCTAssertEqual(RenameEditor.initialText(for: .tab(TabID(rawValue: "w1:t2")), model: model), "Migrate users")
    }

    func testTheRenameKeyNamesTheTabOfAPaneAloneInIt() {
        let model = model()
        XCTAssertEqual(
            RenameShortcut.target(
                focusedPane: PaneID(rawValue: "w1:t1:p1"), selectedTab: TabID(rawValue: "w1:t1"), selectedWorkspace: nil,
                model: model, oneTitle: true
            ),
            .tab(TabID(rawValue: "w1:t1"))
        )
        XCTAssertEqual(
            RenameShortcut.target(
                focusedPane: PaneID(rawValue: "w1:t1:p1"), selectedTab: TabID(rawValue: "w1:t1"), selectedWorkspace: nil,
                model: model, oneTitle: false
            ),
            .pane(PaneID(rawValue: "w1:t1:p1"))
        )
    }

    func testClearPaneNameIsHiddenWhereNothingDrawsThePanesName() {
        var model = model()
        edit(&model, "w1:t1:p1", label: "refunds")
        edit(&model, "w1:t3:p1", label: "agent")
        func hasClear(_ pane: String, oneTitle: Bool) -> Bool {
            PaneMenuModel.entries(for: PaneID(rawValue: pane), model: model, focusedPane: nil, oneTitle: oneTitle)
                .contains { $0.action == .clearPaneName }
        }
        XCTAssertFalse(hasClear("w1:t1:p1", oneTitle: true))
        XCTAssertTrue(hasClear("w1:t1:p1", oneTitle: false))
        XCTAssertTrue(hasClear("w1:t3:p1", oneTitle: true))
    }

    func testADockCardForAPaneAloneInItsTabNamesTheTab() {
        let model = model()
        let alone = AttentionToast.make(kind: .needsInput, pane: pane("w1:t1:p1", in: model), model: model, raisedAt: Date(), oneTitle: true)
        XCTAssertEqual(alone.subject, "api")
        XCTAssertEqual(alone.breadcrumb, "acme")
        let shared = AttentionToast.make(kind: .needsInput, pane: pane("w1:t3:p1", in: model), model: model, raisedAt: Date(), oneTitle: true)
        XCTAssertEqual(shared.subject, "codex")
        XCTAssertEqual(shared.breadcrumb, "acme › tests")
    }

    func testOverviewCardsFollowTheSetting() {
        let model = model()
        let sections = RailSections(model: model, board: nil)
        let card = MissionBoard.card(
            PaneID(rawValue: "w1:t3:p1"), model: model, sections: sections, toasts: AttentionToastStack(),
            history: PaneStatusHistory(), oneTitle: true
        )
        XCTAssertEqual(card?.title, "tests")
        XCTAssertEqual(card?.detail, "codex")
    }

    func testTheToggleIsOnUntilTurnedOffAndRemembered() {
        let name = "PaneNamingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(OneTitleStore(userDefaults: defaults).active)
        OneTitleStore(userDefaults: defaults).select(false)
        XCTAssertFalse(OneTitleStore(userDefaults: defaults).active)
    }
}
