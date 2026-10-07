import FlockCore
import SwiftUI

/// The File and View menus' one-step items, each with its title and
/// shortcut, read by the menu bar and the palette alike.
enum ViewCommand: String, CaseIterable {
    case newTab, newWorkspace, closeTab, closeWorkspace
    case showWorkspaces, showOverview, showArrange
    case rearrangeMode, allWorkspaces, openOldestNotification, clearNotifications, commandPalette
    case backToOverview, openNextCard

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newWorkspace: "New Workspace"
        case .closeTab: "Close Tab"
        case .closeWorkspace: "Close Workspace"
        case .showWorkspaces, .showOverview, .showArrange: viewTab?.title ?? ""
        case .rearrangeMode: "Rearrange Mode"
        case .allWorkspaces: "All Workspaces"
        case .openOldestNotification: "Open Oldest Notification"
        case .backToOverview: "Back to Overview"
        case .openNextCard: "Open Next Card"
        case .clearNotifications: "Clear Notifications"
        case .commandPalette: "Command Palette…"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .newTab: "t"
        case .newWorkspace: "n"
        case .closeTab, .closeWorkspace: "w"
        case .showWorkspaces, .showOverview, .showArrange: KeyEquivalent(viewTab?.digit ?? "0")
        case .rearrangeMode: KeyEquivalent(ArrangeShortcut.rearrangeMode.key)
        case .allWorkspaces: KeyEquivalent(ArrangeShortcut.allWorkspaces.key)
        case .openOldestNotification: "j"
        case .backToOverview: "["
        case .openNextCard: "]"
        case .clearNotifications: "u"
        case .commandPalette: "k"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newTab, .openOldestNotification, .commandPalette, .backToOverview, .openNextCard: .command
        case .newWorkspace, .closeTab, .clearNotifications: [.command, .shift]
        case .closeWorkspace: [.command, .option, .shift]
        case .showWorkspaces, .showOverview, .showArrange: .command
        case .rearrangeMode: ArrangeShortcut.rearrangeMode.modifiers
        case .allWorkspaces: ArrangeShortcut.allWorkspaces.modifiers
        }
    }

    var viewTab: ViewTab? {
        switch self {
        case .showWorkspaces: .workspaces
        case .showOverview: .overview
        case .showArrange: .arrange
        default: nil
        }
    }

    static func show(_ tab: ViewTab) -> ViewCommand {
        switch tab {
        case .workspaces: .showWorkspaces
        case .overview: .showOverview
        case .arrange: .showArrange
        }
    }

    var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    var accessibilityIdentifier: String {
        switch self {
        case .newTab: "flock.file.newTab"
        case .newWorkspace: "flock.file.newWorkspace"
        case .closeTab: "flock.file.closeTab"
        case .closeWorkspace: "flock.file.closeWorkspace"
        case .showWorkspaces: "flock.view.showWorkspaces"
        case .showOverview: "flock.view.showOverview"
        case .showArrange: "flock.view.showArrange"
        case .rearrangeMode: "flock.view.rearrangeMode"
        case .allWorkspaces: "flock.view.allWorkspaces"
        case .openOldestNotification: "flock.view.openOldestNotification"
        case .backToOverview: "flock.view.backToOverview"
        case .openNextCard: "flock.view.openNextCard"
        case .clearNotifications: "flock.view.clearNotifications"
        case .commandPalette: "flock.view.commandPalette"
        }
    }
}
