import FlockCore
import SwiftUI

/// What the palette may offer at one moment, as plain values, so the rules
/// are testable without a window. Each rule is the one the command's own
/// menu item or button uses.
struct PaletteContext {
    var canvasPane: PaneID? = nil
    var neighbors: Set<PaneDirection> = []
    var rtModalUp = false
    var rtInstalled = false
    var rtCommands: [RtCommandRow] = []
    var chatRows: [ChatMenuModel.Row]? = nil
    var focusedAgent: String? = nil
    var launchers: [HarnessEntry] = []
    var rightClickMode: RightClickMode? = nil
    var programHasMouse = false
    var hasSelectedWorkspace = false
    var hasNotifications = false
}

enum PaletteAction {
    case paneMenu(PaneMenuAction)
    case direction(PaneDirectionCommand)
    case chat(ChatMenuItem)
    case rt(RtKind)
    case toggleRightClicks
    case view(ViewCommand)
    case launch(HarnessEntry)
}

struct PaletteEntry {
    let command: PaletteCommand
    let action: PaletteAction
}

enum PaletteCatalog {
    static func entries(in context: PaletteContext) -> [PaletteEntry] {
        rt(context) + launch(context) + pane(context) + chat(context) + mouse(context) + view(context)
    }

    /// Stable across launches while a title stands still, which is all recents need.
    static func id(_ namespace: PaletteNamespace, _ title: String) -> String {
        namespace.rawValue + "." + title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func entry(_ namespace: PaletteNamespace, _ name: String, shortcut: String? = nil, hint: String? = nil,
                              id: String? = nil, _ action: PaletteAction) -> PaletteEntry {
        PaletteEntry(
            command: PaletteCommand(id: id ?? Self.id(namespace, name), namespace: namespace, name: name, shortcut: shortcut, hint: hint),
            action: action
        )
    }

    private static func rt(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.rtInstalled else { return [] }
        return context.rtCommands.map { entry(.rt, $0.kind.rawValue, hint: $0.title, .rt($0.kind)) }
    }

    /// Hidden under a detected agent, whose prompt is not a shell's; any
    /// other program is caught by the runner asking herdr before it types.
    private static func launch(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.canvasPane != nil, context.focusedAgent == nil else { return [] }
        return context.launchers.map { entry(.pane, LauncherSlots.title(for: $0), .launch($0)) }
    }

    private static func pane(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.canvasPane != nil else { return [] }
        let menu = FocusedPaneCommand.all.map {
            entry(.pane, $0.title, shortcut: ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: $0.modifiers), .paneMenu($0.action))
        }
        let extras = [
            entry(.pane, "Zoom Pane", .paneMenu(.zoom)),
            entry(.pane, "Rename Pane", shortcut: ShortcutLabel.text(key: .f2, modifiers: []), .paneMenu(.renamePane)),
        ]
        let directions = PaneDirectionCommand.all
            .filter { context.neighbors.contains($0.direction) && !context.rtModalUp }
            .map { entry(.pane, $0.title, shortcut: ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers), .direction($0)) }
        return menu + extras + directions
    }

    private static func chat(_ context: PaletteContext) -> [PaletteEntry] {
        guard let rows = context.chatRows, context.focusedAgent == ChatButtonModel.claudeAgent else { return [] }
        return rows.filter(\.isEnabled).map {
            entry(.chat, $0.item.title, shortcut: ShortcutLabel.text(key: KeyEquivalent($0.item.key), modifiers: [.command, .shift]), .chat($0.item))
        }
    }

    private static func mouse(_ context: PaletteContext) -> [PaletteEntry] {
        guard context.rightClickMode != nil, context.programHasMouse else { return [] }
        return [entry(
            .mouse, RightClickToggle.title(for: context.rightClickMode), shortcut: "⌥⌘M", id: "mouse.rightclicks", .toggleRightClicks
        )]
    }

    private static func view(_ context: PaletteContext) -> [PaletteEntry] {
        let shortcut = { (command: ViewCommand) in ShortcutLabel.text(key: command.key, modifiers: command.modifiers) }
        var commands: [(PaletteNamespace, ViewCommand)] = [(.view, .rearrangeMode), (.view, .allWorkspaces)]
        if context.hasNotifications { commands += [(.view, .openOldestNotification), (.view, .clearNotifications)] }
        if context.hasSelectedWorkspace { commands.append((.tab, .newTab)) }
        commands.append((.workspace, .newWorkspace))
        return commands.map { entry($0.0, $0.1.title, shortcut: shortcut($0.1), .view($0.1)) }
    }
}
