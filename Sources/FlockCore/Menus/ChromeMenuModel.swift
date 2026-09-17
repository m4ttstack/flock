import Foundation

/// One row of a flat chrome context menu (the strip's tabs, the rail's
/// workspaces). The pane menu has its own entry type because only it carries
/// a submenu.
public struct ChromeMenuEntry<Action: Equatable & Sendable>: Equatable, Sendable {
    public let label: String
    public let action: Action
    public let accessibilityIdentifier: String

    public init(label: String, action: Action, accessibilityIdentifier: String) {
        self.label = label
        self.action = action
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// `newTab` carries the workspace the created tab belongs to, which the tab
/// id alone does not supply at dispatch time.
public enum TabMenuAction: Equatable, Sendable {
    case newTab(WorkspaceID)
    case rename
    case close
}

public enum WorkspaceMenuAction: Equatable, Sendable {
    case rename
    case close
}

/// Pure model for a tab's right-click menu. Mirrors herdr's own
/// `ClientContextMenuTarget::Tab` list (`src/client/shell/context_menu.rs`):
/// New tab, Rename, Close, in that order and unconditionally -- herdr offers
/// Close even on a workspace's last tab, and flock does not second-guess it.
/// Empty for a tab the model does not carry, which is what leaves the view
/// with no menu at all rather than one whose rows name a dead id.
public enum TabMenuModel {
    public static func entries(for tab: TabID, model: SessionModel) -> [ChromeMenuEntry<TabMenuAction>] {
        guard let workspace = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key else { return [] }
        return [
            ChromeMenuEntry(label: "New Tab", action: .newTab(workspace), accessibilityIdentifier: "flock.tab.menu.newTab"),
            ChromeMenuEntry(label: "Rename", action: .rename, accessibilityIdentifier: "flock.tab.menu.rename"),
            ChromeMenuEntry(label: "Close", action: .close, accessibilityIdentifier: "flock.tab.menu.close"),
        ]
    }
}

/// Pure model for a workspace row's right-click menu. herdr's
/// `ClientContextMenuTarget::Workspace` list is Rename + Close plus worktree
/// commands (New worktree, Open worktree..., Delete worktree checkout...,
/// Expand/Collapse); flock mirrors the two it has a capability for and
/// offers none of the worktree rows, since nothing in flock manages a
/// worktree. Empty for a workspace the model does not carry.
public enum WorkspaceMenuModel {
    public static func entries(for workspace: WorkspaceID, model: SessionModel) -> [ChromeMenuEntry<WorkspaceMenuAction>] {
        guard model.workspaces.contains(where: { $0.workspaceID == workspace }) else { return [] }
        return [
            ChromeMenuEntry(label: "Rename", action: .rename, accessibilityIdentifier: "flock.workspace.menu.rename"),
            ChromeMenuEntry(label: "Close", action: .close, accessibilityIdentifier: "flock.workspace.menu.close"),
        ]
    }
}

extension TabMenuAction {
    @MainActor
    public func perform(tabID: TabID, on viewModel: SessionViewModel) async {
        switch self {
        case .newTab(let workspace):
            await viewModel.createTab(in: workspace)
        case .rename:
            viewModel.beginRename(.tab(tabID))
        case .close:
            await viewModel.closeTab(tabID)
        }
    }
}

extension WorkspaceMenuAction {
    @MainActor
    public func perform(workspaceID: WorkspaceID, on viewModel: SessionViewModel) async {
        switch self {
        case .rename:
            viewModel.beginRename(.workspace(workspaceID))
        case .close:
            await viewModel.closeWorkspace(workspaceID)
        }
    }
}
