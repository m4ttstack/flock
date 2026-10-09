import FlockCore
import SwiftUI

/// What the palette may offer at one moment, as plain values, so the rules
/// are testable without a window. Each rule is the one the command's own
/// menu item or button uses.
struct PaletteContext {
    var surface: PaletteSurface = .workspaces
    /// The focused pane on screen: the main canvas's, or the one Overview
    /// shows alone.
    var pane: PaneID? = nil
    var focusedPaneZoomed = false
    var neighbors: Set<PaneDirection> = []
    /// The rt modal or the top-bar overlay covers the main view.
    var modalUp = false
    var rtInstalled = false
    var rtCommands: [RtCommandRow] = []
    var chatRows: [ChatMenuModel.Row]? = nil
    var focusedAgent: String? = nil
    var launchers: [HarnessEntry] = []
    var rightClickMode: RightClickMode? = nil
    var programHasMouse = false
    var hasSelectedWorkspace = false
    var hasNotifications = false
    var hasNextCard = false
    /// The main view's selection is hidden behind the overlay, so nothing that
    /// creates or closes in it is offered.
    var topBarOverlayUp = false
    /// Flock Dev with no rebuild already running.
    var canRebuildDev = false
}

enum PaletteAction {
    case paneMenu(PaneMenuAction)
    case direction(PaneDirectionCommand)
    case chat(ChatMenuItem)
    case rt(RtKind)
    case toggleRightClicks
    case view(ViewCommand)
    case launch(HarnessEntry)
    case rebuildDev
}

struct PaletteEntry {
    let command: PaletteCommand
    let action: PaletteAction
}

enum PaletteCatalog {
    static func entries(in context: PaletteContext) -> [PaletteEntry] {
        (rt(context) + launch(context) + pane(context) + chat(context) + mouse(context) + view(context))
            .filter { $0.command.surfaces.contains(context.surface) }
    }

    /// The rows that act on the focused pane alone, never on the layout or
    /// the tab around it.
    private static let paneSurfaces: Set<PaletteSurface> = [.workspaces, .overviewPane]

    /// Stable across launches while a title stands still, which is all recents need.
    static func id(_ namespace: PaletteNamespace, _ title: String) -> String {
        namespace.rawValue + "." + title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func entry(_ namespace: PaletteNamespace, _ name: String, shortcut: String? = nil, hint: String? = nil,
                              id: String? = nil, on surfaces: Set<PaletteSurface>, _ action: PaletteAction) -> PaletteEntry {
        PaletteEntry(
            command: PaletteCommand(
                id: id ?? Self.id(namespace, name), namespace: namespace, name: name, shortcut: shortcut, hint: hint,
                surfaces: surfaces
            ),
            action: action
        )
    }

    /// `cd` only under Claude Code, whose `/cd` takes the result: a shell
    /// runs rt cd in the pane itself, from the launcher's row.
    private static func rt(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.rtInstalled else { return [] }
        return context.rtCommands
            .filter { $0.kind != .cd || context.focusedAgent == ChatButtonModel.claudeAgent }
            .map { entry(.rt, $0.name, hint: $0.title, on: paneSurfaces, .rt($0.kind)) }
    }

    /// Hidden under a detected agent, whose prompt is not a shell's; any
    /// other program is caught by the runner asking herdr before it types.
    private static func launch(_ context: PaletteContext) -> [PaletteEntry] {
        guard LaunchTarget.pane(canvasPane: context.pane, agent: context.focusedAgent) != nil else { return [] }
        return context.launchers.enumerated().map { index, launcher in
            entry(
                .pane, launcher.paletteName ?? LauncherSlots.title(for: launcher),
                shortcut: LauncherSlots.shortcutLabel(at: index), hint: launcher.paletteHint, on: paneSurfaces,
                .launch(launcher)
            )
        }
    }

    private static func pane(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.pane != nil else { return [] }
        let menu = FocusedPaneCommand.all.map {
            entry(
                .pane, $0.title(zoomed: context.focusedPaneZoomed),
                shortcut: ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: $0.modifiers),
                id: Self.id(.pane, $0.title), on: $0.paletteSurfaces, .paneMenu($0.action)
            )
        }
        let extras = [
            entry(.pane, "Rename Pane", shortcut: ShortcutLabel.text(key: .f2, modifiers: []), on: paneSurfaces, .paneMenu(.renamePane)),
        ]
        let directions = PaneDirectionCommand.all
            .filter { context.neighbors.contains($0.direction) && !context.modalUp }
            .map {
                entry(
                    .pane, $0.title, shortcut: ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers),
                    on: PaneDirectionCommand.paletteSurfaces, .direction($0)
                )
            }
        // Last, since the first row is selected on open and Return would run it.
        let (closes, others) = (menu.filter { $0.command.id == closeID }, menu.filter { $0.command.id != closeID })
        return others + extras + directions + closes
    }

    private static let closeID = id(.pane, FocusedPaneCommand.closePane.title)

    private static func chat(_ context: PaletteContext) -> [PaletteEntry] {
        guard let rows = context.chatRows, context.focusedAgent == ChatButtonModel.claudeAgent else { return [] }
        return rows.filter(\.isEnabled).map {
            entry(
                .chat, $0.item.title, shortcut: ShortcutLabel.text(key: KeyEquivalent($0.item.key), modifiers: [.command, .shift]),
                on: paneSurfaces, .chat($0.item)
            )
        }
    }

    private static func mouse(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.rightClickMode != nil, context.programHasMouse else { return [] }
        return [entry(
            .mouse, RightClickToggle.title(for: context.rightClickMode), shortcut: "⌥⌘M", id: "mouse.rightclicks", on: paneSurfaces,
            .toggleRightClicks
        )]
    }

    private static func view(_ context: PaletteContext) -> [PaletteEntry] {
        let shortcut = { (command: ViewCommand) in ShortcutLabel.text(key: command.key, modifiers: command.modifiers) }
        var commands: [(PaletteNamespace, ViewCommand)] = ViewTab.allCases.map { (.view, ViewCommand.show($0)) }
        commands += [(.view, .rearrangeMode), (.view, .allWorkspaces)]
        if context.hasNotifications { commands += [(.view, .openOldestNotification), (.view, .clearNotifications)] }
        commands.append((.view, .backToOverview))
        if context.hasNextCard { commands.append((.view, .openNextCard)) }
        if !context.topBarOverlayUp {
            if context.hasSelectedWorkspace { commands += [(.tab, .newTab), (.tab, .closeTab)] }
            commands.append((.workspace, .newWorkspace))
            if context.hasSelectedWorkspace { commands.append((.workspace, .closeWorkspace)) }
        }
        let rebuild = context.canRebuildDev
            ? [entry(.view, "Rebuild Flock Dev", hint: "from main", on: PaletteSurface.everywhere, .rebuildDev)] : []
        return commands.map { entry($0.0, $0.1.title, shortcut: shortcut($0.1), on: $0.1.paletteSurfaces, .view($0.1)) } + rebuild
    }
}
