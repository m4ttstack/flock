import XCTest
@testable import FlockCore

/// What each of herdr's actions becomes once it reaches flock: a verb flock
/// has, silence where herdr is silent too, or a message naming what flock
/// will not do.
final class PrefixIntentTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")
    private let right = PaneID(rawValue: "w1:p2")
    private let workspace = WorkspaceID(rawValue: "w1")
    private let tabOne = TabID(rawValue: "w1:t1")
    private let tabTwo = TabID(rawValue: "w1:t2")
    private let tabThree = TabID(rawValue: "w1:t3")

    /// Two panes side by side, the left one focused.
    private var sideBySide: LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: workspace, tabID: tabOne, zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: pane,
            panes: [
                PaneRect(paneID: pane, focused: true, rect: CellRect(x: 0, y: 0, width: 40, height: 24)),
                PaneRect(paneID: right, focused: false, rect: CellRect(x: 40, y: 0, width: 40, height: 24)),
            ],
            splits: []
        )
    }

    private var context: PrefixActionContext {
        PrefixActionContext(
            focusedPane: pane, selectedWorkspace: workspace, selectedTab: tabTwo,
            workspaces: [workspace, WorkspaceID(rawValue: "w2")],
            tabs: [tabOne, tabTwo, tabThree], layout: sideBySide
        )
    }

    private func intent(_ action: HerdrAction, _ context: PrefixActionContext? = nil) -> PrefixIntent {
        PrefixIntents.intent(
            for: HerdrBinding(trigger: .prefixed(HerdrKeyCombo(.character("x"))), label: "prefix+x", action: action),
            in: context ?? self.context
        )
    }

    func testSplitsFollowHerdrsOwnDirections() {
        XCTAssertEqual(intent(.splitVertical), .splitRight(pane), "vertical is side by side")
        XCTAssertEqual(intent(.splitHorizontal), .splitDown(pane), "horizontal is stacked")
    }

    func testPaneVerbsAimAtTheFocusedPane() {
        XCTAssertEqual(intent(.closePane), .closePane(pane))
        XCTAssertEqual(intent(.zoom), .toggleZoom(pane))
        XCTAssertEqual(intent(.renamePane), .beginRename(.pane(pane)))
        XCTAssertEqual(intent(.swapPane(.right)), .swapPane(pane, .right))
    }

    func testFocusPaneAimsAtTheNeighborOnThatSide() {
        XCTAssertEqual(intent(.focusPane(.right)), .focusPane(right))
    }

    /// herdr does nothing when nothing lies that way, so neither does flock.
    func testFocusPaneWithNoNeighborDoesNothing() {
        XCTAssertEqual(intent(.focusPane(.left)), .nothing)
    }

    func testTabAndWorkspaceVerbsAimAtTheSelection() {
        XCTAssertEqual(intent(.newTab), .newTab(workspace))
        XCTAssertEqual(intent(.newWorkspace), .newWorkspace)
        XCTAssertEqual(intent(.closeTab), .closeTab(tabTwo))
        XCTAssertEqual(intent(.closeWorkspace), .closeWorkspace(workspace))
        XCTAssertEqual(intent(.renameTab), .beginRename(.tab(tabTwo)))
        XCTAssertEqual(intent(.renameWorkspace), .beginRename(.workspace(workspace)))
    }

    func testRelativeTabBindingsWrapTheWayHerdrsDo() {
        XCTAssertEqual(intent(.nextTab), .selectTab(tabThree))
        XCTAssertEqual(intent(.previousTab), .selectTab(tabOne))
        var atTheEnd = context
        atTheEnd.selectedTab = tabThree
        XCTAssertEqual(intent(.nextTab, atTheEnd), .selectTab(tabOne))
        var atTheStart = context
        atTheStart.selectedTab = tabOne
        XCTAssertEqual(intent(.previousTab, atTheStart), .selectTab(tabThree))
    }

    func testIndexedBindingsCountFromTheFirst() {
        XCTAssertEqual(intent(.switchTab(0)), .selectTab(tabOne))
        XCTAssertEqual(intent(.switchTab(2)), .selectTab(tabThree))
        XCTAssertEqual(intent(.switchTab(8)), .nothing, "no ninth tab to switch to")
        XCTAssertEqual(intent(.switchWorkspace(1)), .selectWorkspace(WorkspaceID(rawValue: "w2")))
    }

    func testRelativeWorkspaceBindingsWrap() {
        XCTAssertEqual(intent(.nextWorkspace), .selectWorkspace(WorkspaceID(rawValue: "w2")))
        XCTAssertEqual(intent(.previousWorkspace), .selectWorkspace(WorkspaceID(rawValue: "w2")))
    }

    func testAVerbWithNothingToActOnDoesNothing() {
        let empty = PrefixActionContext()
        XCTAssertEqual(intent(.closePane, empty), .nothing)
        XCTAssertEqual(intent(.newTab, empty), .nothing)
        XCTAssertEqual(intent(.closeTab, empty), .nothing)
        XCTAssertEqual(intent(.nextTab, empty), .nothing)
    }

    /// A key flock cannot honour has to say so, so it never reads as a key
    /// that simply did not register.
    func testAnActionFlockDoesNotHaveNamesItselfAndItsField() {
        guard case .notice(let message) = intent(.editScrollback) else {
            return XCTFail("edit_scrollback has no flock verb")
        }
        XCTAssertTrue(message.contains("prefix+x"), message)
        XCTAssertTrue(message.contains("edit_scrollback"), message)
    }

    func testEveryHerdrOnlyActionIsAnnouncedRatherThanIgnored() {
        let herdrOnly: [HerdrAction] = [
            .help, .settings, .reloadConfig, .detach, .copyMode, .editScrollback, .openNavigator,
            .workspacePicker, .newWorktree, .openWorktree, .removeWorktree, .openNotificationTarget,
            .previousAgent, .nextAgent, .focusAgent(0), .lastPane, .cyclePaneNext, .cyclePanePrevious,
            .moveTabPrevious, .moveTabNext, .resizeMode, .resizePane(.left), .toggleSidebar,
        ]
        for action in herdrOnly {
            guard case .notice = intent(action) else {
                return XCTFail("\(action.configName) should announce itself")
            }
        }
    }

    /// A shell or plugin binding is herdr's to run, and saying so is what
    /// keeps the key from reading as broken.
    func testACommandBindingSaysFlockDoesNotRunIt() {
        let command = HerdrCommandBinding(
            command: "m4ttstack.chat.launcher", kind: .pluginAction, summary: "chat launcher"
        )
        guard case .notice(let message) = intent(.command(command)) else {
            return XCTFail("a command binding should announce itself")
        }
        XCTAssertTrue(message.contains("chat launcher"), message)
        XCTAssertTrue(message.contains("prefix+x"), message)
    }

    func testACommandWithNoSummaryNamesTheCommandItself() {
        let command = HerdrCommandBinding(command: "git status", kind: .shell)
        guard case .notice(let message) = intent(.command(command)) else {
            return XCTFail("a command binding should announce itself")
        }
        XCTAssertTrue(message.contains("git status"), message)
    }
}
