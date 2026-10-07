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
    case toggleComplete
    case close
}

public enum WorkspaceMenuAction: Equatable, Sendable {
    case rename
    case pin
    case unpin
    case changeFolder
    case close
}

public enum EmptyPinMenuAction: Equatable, Sendable {
    case rename
    case changeFolder
    case remove
}

public enum RailMenuAction: Equatable, Sendable {
    case newWorkspace
}

/// Pure model for a tab's right-click menu. Mirrors herdr's own
/// `ClientContextMenuTarget::Tab` list (`src/client/shell/context_menu.rs`):
/// New tab, Rename, Close, in that order and unconditionally, with flock's
/// own completion row (`TabCompletionStore`) between Rename and Close. herdr offers
/// Close on a workspace's last tab too, and so does flock; what differs is
/// what the row then does. herdr closes the workspace outright, while flock
/// asks first, since a close cannot be undone (`CloseConsequence`, reached
/// through `SessionViewModel.closeTab`). The row is never hidden or disabled
/// for it: the verb stays available, it just says what it costs.
/// Empty for a tab the model does not carry, which is what leaves the view
/// with no menu at all rather than one whose rows name a dead id.
public enum TabMenuModel {
    public static func entries(for tab: TabID, model: SessionModel, isComplete: Bool) -> [ChromeMenuEntry<TabMenuAction>] {
        guard let workspace = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key else { return [] }
        return [
            ChromeMenuEntry(label: "New Tab", action: .newTab(workspace), accessibilityIdentifier: "flock.tab.menu.newTab"),
            ChromeMenuEntry(label: "Rename", action: .rename, accessibilityIdentifier: "flock.tab.menu.rename"),
            ChromeMenuEntry(
                label: isComplete ? "Mark Incomplete" : "Mark Complete", action: .toggleComplete,
                accessibilityIdentifier: "flock.tab.menu.complete"
            ),
            ChromeMenuEntry(label: "Close", action: .close, accessibilityIdentifier: "flock.tab.menu.close"),
        ]
    }
}

/// Pure model for a workspace row's right-click menu. herdr's
/// `ClientContextMenuTarget::Workspace` list is Rename + Close plus worktree
/// commands (New worktree, Open worktree..., Delete worktree checkout...,
/// Expand/Collapse); flock mirrors Rename and Close, adds Pin, and offers none
/// of the worktree rows, since nothing in flock manages a worktree. A pinned
/// workspace offers Change Folder... and Unpin in place of Close. Empty for a
/// workspace the model does not carry.
public enum WorkspaceMenuModel {
    public static func entries(for workspace: WorkspaceID, model: SessionModel, isPinned: Bool = false) -> [ChromeMenuEntry<WorkspaceMenuAction>] {
        guard model.workspaces.contains(where: { $0.workspaceID == workspace }) else { return [] }
        let rename = ChromeMenuEntry(label: "Rename", action: WorkspaceMenuAction.rename, accessibilityIdentifier: "flock.workspace.menu.rename")
        guard !isPinned else {
            return [
                rename,
                ChromeMenuEntry(label: "Change Folder\u{2026}", action: .changeFolder, accessibilityIdentifier: "flock.workspace.menu.changeFolder"),
                ChromeMenuEntry(label: "Unpin", action: .unpin, accessibilityIdentifier: "flock.workspace.menu.unpin"),
            ]
        }
        return [
            rename,
            ChromeMenuEntry(label: "Pin", action: .pin, accessibilityIdentifier: "flock.workspace.menu.pin"),
            ChromeMenuEntry(label: "Close", action: .close, accessibilityIdentifier: "flock.workspace.menu.close"),
        ]
    }
}

/// Pure model for an empty pin's right-click menu: a pin with no live workspace.
public enum EmptyPinMenuModel {
    public static func entries() -> [ChromeMenuEntry<EmptyPinMenuAction>] {
        [
            ChromeMenuEntry(label: "Rename", action: .rename, accessibilityIdentifier: "flock.pin.menu.rename"),
            ChromeMenuEntry(label: "Change Folder\u{2026}", action: .changeFolder, accessibilityIdentifier: "flock.pin.menu.changeFolder"),
            ChromeMenuEntry(label: "Remove", action: .remove, accessibilityIdentifier: "flock.pin.menu.remove"),
        ]
    }
}

/// Pure model for the menu on rail space no workspace row occupies. This one
/// mirrors nothing in herdr, whose context menus target only a workspace, a
/// tab or a pane: it is the second way to the "+" herdr draws in its own
/// sidebar, beside the rail's plain click and File > New Workspace. It takes
/// no id and no model, since empty rail names nothing.
public enum RailMenuModel {
    public static func entries() -> [ChromeMenuEntry<RailMenuAction>] {
        [ChromeMenuEntry(label: "New Workspace", action: .newWorkspace, accessibilityIdentifier: "flock.rail.menu.newWorkspace")]
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
        case .toggleComplete:
            viewModel.completedTabs.toggle(tabID)
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
        case .pin:
            viewModel.pin(workspace: workspaceID)
        case .unpin:
            if let pin = viewModel.pins.pin(linkedTo: workspaceID) { viewModel.unpin(pin.id) }
        case .changeFolder:
            break
        case .close:
            await viewModel.closeWorkspace(workspaceID)
        }
    }
}

extension RailMenuAction {
    @MainActor
    public func perform(on viewModel: SessionViewModel) async {
        switch self {
        case .newWorkspace:
            await viewModel.createWorkspace()
        }
    }
}
