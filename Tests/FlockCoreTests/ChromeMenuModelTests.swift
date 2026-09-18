import XCTest
@testable import FlockCore

/// The tab and workspace context menus against herdr's own lists
/// (`src/client/shell/context_menu.rs`, tracked in `docs/design/PARITY.md`).
final class ChromeMenuModelTests: XCTestCase {
    private static let workspace = WorkspaceID(rawValue: "w1")
    private static let otherWorkspace = WorkspaceID(rawValue: "w2")
    private static let tab = TabID(rawValue: "w1:t1")
    private static let otherTab = TabID(rawValue: "w2:t1")

    private func model() -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [
                WorkspaceRecord(workspaceID: Self.workspace, label: "one", number: 1, activeTabID: Self.tab, agentStatus: .idle),
                WorkspaceRecord(workspaceID: Self.otherWorkspace, label: "two", number: 2, activeTabID: Self.otherTab, agentStatus: .idle),
            ],
            tabs: [
                TabRecord(tabID: Self.tab, workspaceID: Self.workspace, label: "first", number: 1, paneCount: 1, agentStatus: .idle),
                TabRecord(tabID: Self.otherTab, workspaceID: Self.otherWorkspace, label: "second", number: 1, paneCount: 1, agentStatus: .idle),
            ],
            panes: [],
            layouts: []
        ))
    }

    // MARK: - Tab menu

    func testTheTabMenuMirrorsHerdrsThreeRowsInOrder() {
        let entries = TabMenuModel.entries(for: Self.tab, model: model())

        XCTAssertEqual(entries.map(\.label), ["New Tab", "Rename", "Close"])
        XCTAssertEqual(entries.map(\.accessibilityIdentifier), [
            "flock.tab.menu.newTab", "flock.tab.menu.rename", "flock.tab.menu.close",
        ])
        XCTAssertEqual(entries.map(\.action), [.newTab(Self.workspace), .rename, .close])
    }

    /// The created tab belongs to the RIGHT-CLICKED tab's own workspace, not
    /// to whatever the rail has selected: a tab menu can be opened from a
    /// grid card of another workspace.
    func testNewTabCarriesTheRightClickedTabsOwnWorkspace() {
        let entries = TabMenuModel.entries(for: Self.otherTab, model: model())

        XCTAssertEqual(entries.first?.action, .newTab(Self.otherWorkspace))
    }

    /// herdr offers Close on every tab, a workspace's last one included, so
    /// flock does not add a guard herdr does not have.
    func testCloseIsOfferedOnAWorkspacesOnlyTab() {
        XCTAssertEqual(model().tabs[Self.otherWorkspace]?.count, 1)

        XCTAssertTrue(TabMenuModel.entries(for: Self.otherTab, model: model()).contains { $0.action == .close })
    }

    func testATabTheModelDoesNotCarryHasNoMenuAtAll() {
        XCTAssertTrue(TabMenuModel.entries(for: TabID(rawValue: "ghost"), model: model()).isEmpty)
    }

    // MARK: - Workspace menu

    func testTheWorkspaceMenuMirrorsHerdrsTwoNonWorktreeRows() {
        let entries = WorkspaceMenuModel.entries(for: Self.workspace, model: model())

        XCTAssertEqual(entries.map(\.label), ["Rename", "Close"])
        XCTAssertEqual(entries.map(\.accessibilityIdentifier), [
            "flock.workspace.menu.rename", "flock.workspace.menu.close",
        ])
        XCTAssertEqual(entries.map(\.action), [.rename, .close])
    }

    func testAWorkspaceTheModelDoesNotCarryHasNoMenuAtAll() {
        XCTAssertTrue(WorkspaceMenuModel.entries(for: WorkspaceID(rawValue: "ghost"), model: model()).isEmpty)
    }

    // MARK: - Rail menu

    /// Rail space no row occupies. herdr has no menu here to mirror, so the
    /// one row is the rail's own plain-click verb, named as File > New
    /// Workspace names it.
    func testTheRailMenuOffersNewWorkspace() {
        let entries = RailMenuModel.entries()

        XCTAssertEqual(entries.map(\.label), ["New Workspace"])
        XCTAssertEqual(entries.map(\.accessibilityIdentifier), ["flock.rail.menu.newWorkspace"])
        XCTAssertEqual(entries.map(\.action), [.newWorkspace])
    }
}
