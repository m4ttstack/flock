import SwiftUI

/// The File and View menus' one-step items, each with its title and
/// shortcut, read by the menu bar and the palette alike.
enum ViewCommand: String, CaseIterable {
    case newTab, newWorkspace, rearrangeMode, allWorkspaces, openOldestNotification, clearNotifications, commandPalette

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newWorkspace: "New Workspace"
        case .rearrangeMode: "Rearrange Mode"
        case .allWorkspaces: "All Workspaces"
        case .openOldestNotification: "Open Oldest Notification"
        case .clearNotifications: "Clear Notifications"
        case .commandPalette: "Command Palette…"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .newTab: "t"
        case .newWorkspace: "n"
        case .rearrangeMode: KeyEquivalent(ArrangeShortcut.rearrangeMode.key)
        case .allWorkspaces: KeyEquivalent(ArrangeShortcut.allWorkspaces.key)
        case .openOldestNotification: "j"
        case .clearNotifications, .commandPalette: "k"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newTab, .openOldestNotification, .commandPalette: .command
        case .newWorkspace, .clearNotifications: [.command, .shift]
        case .rearrangeMode: ArrangeShortcut.rearrangeMode.modifiers
        case .allWorkspaces: ArrangeShortcut.allWorkspaces.modifiers
        }
    }

    var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    var accessibilityIdentifier: String {
        switch self {
        case .newTab: "flock.file.newTab"
        case .newWorkspace: "flock.file.newWorkspace"
        case .rearrangeMode: "flock.view.rearrangeMode"
        case .allWorkspaces: "flock.view.allWorkspaces"
        case .openOldestNotification: "flock.view.openOldestNotification"
        case .clearNotifications: "flock.view.clearNotifications"
        case .commandPalette: "flock.view.commandPalette"
        }
    }
}
