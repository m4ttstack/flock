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

    func testTheFocusedViewsKeysAreOfferedOnlyInTheFocusedView() {
        let workspaces = ids(PaletteContext(hasNotifications: true, hasNextCard: true))
        XCTAssertFalse(workspaces.contains("view.backtooverview"))
        XCTAssertFalse(workspaces.contains("view.opennextcard"))

        let focused = ids(PaletteContext(surface: .overviewPane, pane: pane, hasNextCard: true))
        XCTAssertTrue(focused.contains("view.backtooverview"))
        XCTAssertTrue(focused.contains("view.opennextcard"))
        XCTAssertFalse(
            ids(PaletteContext(surface: .overviewPane, pane: pane)).contains("view.opennextcard"), "no other card waiting"
        )
    }

    /// The pane is drawn alone and the Workspaces selection is hidden, so
    /// nothing that reshapes a layout or creates and closes in the selection
    /// is offered; what acts on the pane itself is.
    func testTheOverviewPaneOffersThePaneButNotItsLayoutOrTheHiddenSelection() {
        let listed = ids(PaletteContext(
            surface: .overviewPane, pane: pane, neighbors: [.left, .right], rtInstalled: true, rtCommands: rtRows,
            chatRows: chatRows, focusedAgent: ChatButtonModel.claudeAgent, rightClickMode: .program, programHasMouse: true,
            hasSelectedWorkspace: true, hasNotifications: true, canRebuildDev: true
        ))
        for id in ["rt.glitter", "chat.quicksend", "mouse.rightclicks", "pane.renamepane", "pane.closepane",
                   "view.workspaces", "view.arrange", "view.clearnotifications", "view.rebuildflockdev"] {
            XCTAssertTrue(listed.contains(id), "\(id) missing")
        }
        for id in ["pane.splitright", "pane.splitdown", "pane.zoompane", "pane.focuspaneleft", "pane.swappaneright",
                   "view.overview", "view.rearrangemode", "view.allworkspaces"] {
            XCTAssertFalse(listed.contains(id), "\(id) listed")
        }
        XCTAssertFalse(listed.contains { $0.hasPrefix("tab.") || $0.hasPrefix("workspace.") })
    }

    func testEveryRowIsOfferedOnlyOnASurfaceItNames() {
        let context = PaletteContext(
            pane: pane, neighbors: Set(PaneDirection.allCases), rtInstalled: true, rtCommands: rtRows, chatRows: chatRows,
            focusedAgent: ChatButtonModel.claudeAgent, rightClickMode: .program, programHasMouse: true,
            hasSelectedWorkspace: true, hasNotifications: true, hasNextCard: true, canRebuildDev: true
        )
        for surface in PaletteSurface.allCases {
            var onSurface = context
            onSurface.surface = surface
            for entry in PaletteCatalog.entries(in: onSurface) {
                XCTAssertTrue(entry.command.surfaces.contains(surface), "\(entry.command.id) on \(surface)")
            }
        }
    }

    func testEveryViewCommandButThePaletteNamesASurface() {
        for command in ViewCommand.allCases where command != .commandPalette {
            XCTAssertFalse(command.paletteSurfaces.isEmpty, "\(command)")
        }
        XCTAssertTrue(ViewCommand.commandPalette.paletteSurfaces.isEmpty)
    }

    func testRebuildFlockDevIsOfferedOnlyWhenARebuildCanStart() {
        XCTAssertTrue(ids(PaletteContext(canRebuildDev: true)).contains("view.rebuildflockdev"))
        XCTAssertFalse(ids(PaletteContext()).contains("view.rebuildflockdev"), "the release app, or a rebuild already running")
    }

    func testTheOtherViewsAreListedWithTheirKeys() {
        let entries = PaletteCatalog.entries(in: PaletteContext())
        let shortcut = { (id: String) in entries.first { $0.command.id == id }?.command.shortcut }
        XCTAssertNil(shortcut("view.workspaces"), "the palette is drawn over Workspaces, so it does not offer it")
        XCTAssertEqual(shortcut("view.overview"), "⌘2")
        XCTAssertEqual(shortcut("view.arrange"), "⌘3")
        let fromArrange = ids(PaletteContext(surface: .arrange))
        XCTAssertTrue(fromArrange.contains("view.workspaces"))
        XCTAssertFalse(fromArrange.contains("view.arrange"))
    }

    func testAPlainShellPaneListsPaneRtViewAndCreationButNoChatOrMouse() {
        let listed = ids(PaletteContext(
            pane: pane, neighbors: [.right], rtInstalled: true, rtCommands: rtRows, chatRows: chatRows,
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
            pane: pane, chatRows: chatRows, focusedAgent: ChatButtonModel.claudeAgent,
            rightClickMode: .program, programHasMouse: true
        ))
        let listed = entries.map(\.command.id)
        XCTAssertTrue(listed.contains("chat.quicksend"))
        XCTAssertFalse(listed.contains("chat.signoutthispane"), "a disabled chat row is not listed")
        XCTAssertEqual(entries.first { $0.command.id == "mouse.rightclicks" }?.command.name, "Give Right-Clicks to Flock")
    }

    func testRtRowsAreNamedByVerbWithThePopoverTitleAsHint() {
        let entry = PaletteCatalog.entries(in: PaletteContext(pane: pane, rtInstalled: true, rtCommands: rtRows))
            .first { $0.command.id == "rt.glitter" }
        XCTAssertEqual(entry?.command.name, "glitter")
        XCTAssertEqual(entry?.command.hint, "Review and commit")
        XCTAssertNil(entry?.command.shortcut)
    }

    func testNoRtRowsWithoutRt() {
        XCTAssertFalse(ids(PaletteContext(pane: pane, rtInstalled: false, rtCommands: rtRows)).contains { $0.hasPrefix("rt.") })
    }

    /// Over the rt modal the canvas has no focused pane, as the menus see it.
    func testWhileTheRtModalIsUpNoPaneCommandsAreListed() {
        let listed = ids(PaletteContext(pane: nil, neighbors: [.left, .right], modalUp: true, rtInstalled: true, rtCommands: rtRows))
        XCTAssertFalse(listed.contains { $0.hasPrefix("pane.") })
        XCTAssertTrue(listed.contains("rt.glitter"))
    }

    func testWhileTheTopBarOverlayIsUpNothingActsOnTheHiddenSelection() {
        let listed = ids(PaletteContext(
            pane: nil, neighbors: [.left, .right], modalUp: true, hasSelectedWorkspace: true, topBarOverlayUp: true
        ))
        XCTAssertFalse(listed.contains("pane.focuspaneleft"))
        XCTAssertFalse(listed.contains { $0.hasPrefix("tab.") || $0.hasPrefix("workspace.") })
        XCTAssertTrue(listed.contains("view.rearrangemode"))
    }

    func testLaunchersAreListedForAShellPaneButNotUnderAnAgent() {
        let launchers = LauncherSlots.ordered(navigator: NavigatorRoster.rtCd, entries: HarnessRoster.known)
        let commands = PaletteCatalog.entries(in: PaletteContext(pane: pane, launchers: launchers))
            .filter { if case .launch = $0.action { true } else { false } }
            .map(\.command)
        XCTAssertEqual(commands.map(\.name), ["rt cd", "Claude", "Codex"])
        XCTAssertEqual(commands.map(\.hint), [nil, "Launch Claude Code CLI", "Launch Codex CLI"])

        let underClaude = ids(PaletteContext(pane: pane, focusedAgent: ChatButtonModel.claudeAgent, launchers: launchers))
        XCTAssertFalse(underClaude.contains("pane.codex"), "claude's prompt would take the command as a message")
        XCTAssertFalse(ids(PaletteContext(pane: nil, launchers: launchers)).contains("pane.rtcd"))
    }

    func testLaunchRowsShowTheKeyOfTheirLauncherSlot() {
        let launchers = LauncherSlots.ordered(navigator: NavigatorRoster.rtCd, entries: HarnessRoster.known)
        let launchRows = PaletteCatalog.entries(in: PaletteContext(pane: pane, launchers: launchers))
            .filter { if case .launch = $0.action { true } else { false } }
        XCTAssertEqual(launchRows.map(\.command.shortcut), ["⌘1", "⌘2", "⌘3"])

        let withoutRt = LauncherSlots.ordered(navigator: nil, entries: HarnessRoster.known)
        let claudeFirst = PaletteCatalog.entries(in: PaletteContext(pane: pane, launchers: withoutRt))
            .first { $0.command.id == "pane.claude" }
        XCTAssertEqual(claudeFirst?.command.shortcut, "⌘1", "a number names a slot, so it moves with the row")
    }

    /// A shell has the launcher's in-pane `rt cd`; Claude's prompt is not a
    /// shell's, so its pane gets the modal instead.
    func testTheRtCdModalIsListedOnlyUnderClaude() {
        let launchers = LauncherSlots.ordered(navigator: NavigatorRoster.rtCd, entries: HarnessRoster.known)
        let shell = ids(PaletteContext(pane: pane, rtInstalled: true, rtCommands: rtRows, launchers: launchers))
        XCTAssertFalse(shell.contains("rt.cd"))
        XCTAssertTrue(shell.contains("pane.rtcd"))

        let claude = ids(PaletteContext(
            pane: pane, rtInstalled: true, rtCommands: rtRows, focusedAgent: ChatButtonModel.claudeAgent, launchers: launchers
        ))
        XCTAssertTrue(claude.contains("rt.cd"))
        XCTAssertFalse(claude.contains("pane.rtcd"))

        let codex = ids(PaletteContext(pane: pane, rtInstalled: true, rtCommands: rtRows, focusedAgent: "codex"))
        XCTAssertFalse(codex.contains("rt.cd"), "codex has no /cd")
    }

    /// Renamed, not re-identified, so recents still find it after a zoom.
    func testTheZoomRowNamesTheWayOutWhileZoomed() {
        let name = { (zoomed: Bool) in
            PaletteCatalog.entries(in: PaletteContext(pane: self.pane, focusedPaneZoomed: zoomed))
                .first { $0.command.id == "pane.zoompane" }?.command.name
        }
        XCTAssertEqual(name(false), "Zoom Pane")
        XCTAssertEqual(name(true), "Unzoom Pane")
    }

    func testShortcutsReadAsTheMenusShowThem() {
        let entries = PaletteCatalog.entries(in: PaletteContext(pane: pane, neighbors: [.left], hasNotifications: true))
        let shortcut = { (id: String) in entries.first { $0.command.id == id }?.command.shortcut }
        XCTAssertEqual(shortcut("pane.splitright"), "⌘D")
        XCTAssertEqual(shortcut("pane.focuspaneleft"), "⌥⌘←")
        XCTAssertEqual(shortcut("pane.renamepane"), "F2")
        XCTAssertEqual(shortcut("pane.zoompane"), "⇧⌘↩")
        XCTAssertEqual(shortcut("view.clearnotifications"), "⇧⌘U")
        XCTAssertFalse(entries.contains { $0.command.id == "view.commandpalette" }, "the palette does not list itself")
    }
}
