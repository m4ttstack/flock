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
