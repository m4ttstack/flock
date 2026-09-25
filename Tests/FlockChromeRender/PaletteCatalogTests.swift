import XCTest
@testable import FlockCore

@MainActor
final class PaletteCatalogTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")
    private let rtRows = RtPopoverModel.commands(hasRunner: false)
    private let chatRows = ChatMenuItem.allCases.map { ChatMenuModel.Row(item: $0, isEnabled: $0 != .signOut) }

    private func ids(_ context: PaletteContext) -> [String] {
        PaletteCatalog.entries(in: context).map(\.command.id)
    }

    func testAPlainShellPaneListsPaneRtViewAndCreationButNoChatOrMouse() {
        let listed = ids(PaletteContext(
            canvasPane: pane, neighbors: [.right], rtInstalled: true, rtCommands: rtRows, chatRows: chatRows,
            rightClickMode: .program, hasSelectedWorkspace: true
        ))
        XCTAssertTrue(listed.contains("rt.glitter"))
        XCTAssertTrue(listed.contains("pane.splitright"))
        XCTAssertTrue(listed.contains("pane.focuspaneright"))
        XCTAssertFalse(listed.contains("pane.focuspaneleft"), "no neighbor to the left")
        XCTAssertFalse(listed.contains { $0.hasPrefix("chat.") }, "a shell pane is not running Claude Code")
        XCTAssertFalse(listed.contains("mouse.rightclicks"), "the program has not claimed the mouse")
        XCTAssertTrue(listed.contains("view.rearrangemode"))
        XCTAssertTrue(listed.contains("tab.newtab"))
        XCTAssertTrue(listed.contains("workspace.newworkspace"))
        XCTAssertFalse(listed.contains("view.clearnotifications"), "nothing to clear")
    }

    func testAClaudePaneWithTheMouseListsChatAndTheToggle() {
        let entries = PaletteCatalog.entries(in: PaletteContext(
            canvasPane: pane, chatRows: chatRows, focusedAgent: ChatButtonModel.claudeAgent,
            rightClickMode: .program, programHasMouse: true
        ))
        let listed = entries.map(\.command.id)
        XCTAssertTrue(listed.contains("chat.quicksend"))
        XCTAssertFalse(listed.contains("chat.signoutthispane"), "a disabled chat row is not listed")
        XCTAssertEqual(entries.first { $0.command.id == "mouse.rightclicks" }?.command.name, "Give Right-Clicks to Flock")
    }

    func testRtRowsAreNamedByVerbWithThePopoverTitleAsHint() {
        let entry = PaletteCatalog.entries(in: PaletteContext(canvasPane: pane, rtInstalled: true, rtCommands: rtRows))
            .first { $0.command.id == "rt.glitter" }
        XCTAssertEqual(entry?.command.name, "glitter")
        XCTAssertEqual(entry?.command.hint, "Review and commit")
        XCTAssertNil(entry?.command.shortcut)
    }

    func testNoRtRowsWithoutRt() {
        XCTAssertFalse(ids(PaletteContext(canvasPane: pane, rtInstalled: false, rtCommands: rtRows)).contains { $0.hasPrefix("rt.") })
    }

    /// Over the rt modal the canvas has no focused pane, as the menus see it.
    func testWhileTheRtModalIsUpNoPaneCommandsAreListed() {
        let listed = ids(PaletteContext(canvasPane: nil, neighbors: [.left, .right], rtModalUp: true, rtInstalled: true, rtCommands: rtRows))
        XCTAssertFalse(listed.contains { $0.hasPrefix("pane.") })
        XCTAssertTrue(listed.contains("rt.glitter"))
    }

    func testLaunchersAreListedForAShellPaneButNotUnderAnAgent() {
        let launchers = LauncherSlots.ordered(navigator: NavigatorRoster.rtCd, entries: HarnessRoster.known)
        let commands = PaletteCatalog.entries(in: PaletteContext(canvasPane: pane, launchers: launchers))
            .filter { if case .launch = $0.action { true } else { false } }
            .map(\.command)
        XCTAssertEqual(commands.map(\.name), ["rt cd", "Claude", "Codex"])
        XCTAssertEqual(commands.map(\.hint), [nil, "Launch Claude Code CLI", "Launch Codex CLI"])

        let underClaude = ids(PaletteContext(canvasPane: pane, focusedAgent: ChatButtonModel.claudeAgent, launchers: launchers))
        XCTAssertFalse(underClaude.contains("pane.codex"), "claude's prompt would take the command as a message")
        XCTAssertFalse(ids(PaletteContext(canvasPane: nil, launchers: launchers)).contains("pane.rtcd"))
    }

    /// A shell has the launcher's in-pane `rt cd`; Claude's prompt is not a
    /// shell's, so its pane gets the modal instead.
    func testTheRtCdModalIsListedOnlyUnderClaude() {
        let launchers = LauncherSlots.ordered(navigator: NavigatorRoster.rtCd, entries: HarnessRoster.known)
        let shell = ids(PaletteContext(canvasPane: pane, rtInstalled: true, rtCommands: rtRows, launchers: launchers))
        XCTAssertFalse(shell.contains("rt.cd"))
        XCTAssertTrue(shell.contains("pane.rtcd"))

        let claude = ids(PaletteContext(
            canvasPane: pane, rtInstalled: true, rtCommands: rtRows, focusedAgent: ChatButtonModel.claudeAgent, launchers: launchers
        ))
        XCTAssertTrue(claude.contains("rt.cd"))
        XCTAssertFalse(claude.contains("pane.rtcd"))

        let codex = ids(PaletteContext(canvasPane: pane, rtInstalled: true, rtCommands: rtRows, focusedAgent: "codex"))
        XCTAssertFalse(codex.contains("rt.cd"), "codex has no /cd")
    }

    func testShortcutsReadAsTheMenusShowThem() {
        let entries = PaletteCatalog.entries(in: PaletteContext(canvasPane: pane, neighbors: [.left], hasNotifications: true))
        let shortcut = { (id: String) in entries.first { $0.command.id == id }?.command.shortcut }
        XCTAssertEqual(shortcut("pane.splitright"), "⌘D")
        XCTAssertEqual(shortcut("pane.focuspaneleft"), "⌥⌘←")
        XCTAssertEqual(shortcut("pane.renamepane"), "F2")
        XCTAssertEqual(shortcut("view.clearnotifications"), "⇧⌘K")
        XCTAssertFalse(entries.contains { $0.command.id == "view.commandpalette" }, "the palette does not list itself")
    }
}
