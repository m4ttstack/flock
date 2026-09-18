import Foundation

/// The slice of the session a bound key needs to know what it acts on.
public struct PrefixActionContext: Equatable, Sendable {
    public var focusedPane: PaneID?
    public var selectedWorkspace: WorkspaceID?
    public var selectedTab: TabID?
    /// Every workspace, in herdr's own order, which is what an indexed or
    /// relative workspace binding counts through.
    public var workspaces: [WorkspaceID]
    /// The selected workspace's tabs, in herdr's own order.
    public var tabs: [TabID]
    /// The layout holding the focused pane, for the directional bindings.
    public var layout: LayoutSnapshot?

    public init(
        focusedPane: PaneID? = nil,
        selectedWorkspace: WorkspaceID? = nil,
        selectedTab: TabID? = nil,
        workspaces: [WorkspaceID] = [],
        tabs: [TabID] = [],
        layout: LayoutSnapshot? = nil
    ) {
        self.focusedPane = focusedPane
        self.selectedWorkspace = selectedWorkspace
        self.selectedTab = selectedTab
        self.workspaces = workspaces
        self.tabs = tabs
        self.layout = layout
    }
}

/// One bound key resolved all the way down to the flock verb it runs, so the
/// whole rule is decided here and the app layer only makes the call.
public enum PrefixIntent: Equatable, Sendable {
    case focusPane(PaneID)
    case selectTab(TabID)
    case selectWorkspace(WorkspaceID)
    case splitRight(PaneID)
    case splitDown(PaneID)
    case closePane(PaneID)
    case closeTab(TabID)
    case closeWorkspace(WorkspaceID)
    case newTab(WorkspaceID)
    case newWorkspace
    case toggleZoom(PaneID)
    case swapPane(PaneID, PaneDirection)
    case beginRename(RenameTarget)
    /// Say this to the user and change nothing. What every binding flock
    /// cannot honour comes to, so such a key reads as understood-and-declined
    /// rather than dead.
    case notice(String)
    /// A binding flock does honour, aimed at something that is not there:
    /// herdr does nothing in the same situation, so neither does this.
    case nothing
}

public enum PrefixIntents {
    public static func intent(for binding: HerdrBinding, in context: PrefixActionContext) -> PrefixIntent {
        switch binding.action {
        case .newTab:
            return context.selectedWorkspace.map(PrefixIntent.newTab) ?? .nothing
        case .newWorkspace:
            return .newWorkspace
        case .closeTab:
            return context.selectedTab.map(PrefixIntent.closeTab) ?? .nothing
        case .closeWorkspace:
            return context.selectedWorkspace.map(PrefixIntent.closeWorkspace) ?? .nothing
        case .closePane:
            return context.focusedPane.map(PrefixIntent.closePane) ?? .nothing
        case .splitVertical:
            return context.focusedPane.map(PrefixIntent.splitRight) ?? .nothing
        case .splitHorizontal:
            return context.focusedPane.map(PrefixIntent.splitDown) ?? .nothing
        case .zoom:
            return context.focusedPane.map(PrefixIntent.toggleZoom) ?? .nothing
        case .focusPane(let direction):
            guard let pane = context.focusedPane, let layout = context.layout,
                  let neighbor = PaneNeighbors.pane(pane, toward: direction, in: layout)
            else { return .nothing }
            return .focusPane(neighbor)
        case .swapPane(let direction):
            return context.focusedPane.map { .swapPane($0, direction) } ?? .nothing
        case .previousTab:
            return step(context.tabs, from: context.selectedTab, by: -1).map(PrefixIntent.selectTab) ?? .nothing
        case .nextTab:
            return step(context.tabs, from: context.selectedTab, by: 1).map(PrefixIntent.selectTab) ?? .nothing
        case .switchTab(let index):
            return context.tabs.indices.contains(index) ? .selectTab(context.tabs[index]) : .nothing
        case .previousWorkspace:
            return step(context.workspaces, from: context.selectedWorkspace, by: -1)
                .map(PrefixIntent.selectWorkspace) ?? .nothing
        case .nextWorkspace:
            return step(context.workspaces, from: context.selectedWorkspace, by: 1)
                .map(PrefixIntent.selectWorkspace) ?? .nothing
        case .switchWorkspace(let index):
            return context.workspaces.indices.contains(index)
                ? .selectWorkspace(context.workspaces[index]) : .nothing
        case .renamePane:
            return context.focusedPane.map { .beginRename(.pane($0)) } ?? .nothing
        case .renameTab:
            return context.selectedTab.map { .beginRename(.tab($0)) } ?? .nothing
        case .renameWorkspace:
            return context.selectedWorkspace.map { .beginRename(.workspace($0)) } ?? .nothing
        case .command(let command):
            return .notice(
                "\(binding.label) runs \(command.summary ?? command.command) in herdr; flock does not run herdr command bindings"
            )
        default:
            return .notice("\(binding.label) is herdr's \(binding.action.configName); flock has no equivalent")
        }
    }

    /// The element `delta` places along from the current one, wrapping, which
    /// is how herdr's own relative tab and workspace bindings move.
    private static func step<Element: Equatable>(
        _ elements: [Element], from current: Element?, by delta: Int
    ) -> Element? {
        guard let current, let index = elements.firstIndex(of: current), !elements.isEmpty else { return nil }
        let count = elements.count
        return elements[((index + delta) % count + count) % count]
    }
}

extension HerdrAction {
    /// The `[keys]` field this action is bound through, so a message about it
    /// names something the user can find in their own config.
    public var configName: String {
        switch self {
        case .help: "help"
        case .settings: "settings"
        case .newWorkspace: "new_workspace"
        case .newWorktree: "new_worktree"
        case .openWorktree: "open_worktree"
        case .removeWorktree: "remove_worktree"
        case .renameWorkspace: "rename_workspace"
        case .closeWorkspace: "close_workspace"
        case .workspacePicker: "workspace_picker"
        case .openNavigator: "goto"
        case .detach: "detach"
        case .reloadConfig: "reload_config"
        case .openNotificationTarget: "open_notification_target"
        case .previousWorkspace: "previous_workspace"
        case .nextWorkspace: "next_workspace"
        case .previousAgent: "previous_agent"
        case .nextAgent: "next_agent"
        case .focusAgent: "focus_agent"
        case .newTab: "new_tab"
        case .renameTab: "rename_tab"
        case .previousTab: "previous_tab"
        case .nextTab: "next_tab"
        case .moveTabPrevious: "move_tab_previous"
        case .moveTabNext: "move_tab_next"
        case .switchTab: "switch_tab"
        case .switchWorkspace: "switch_workspace"
        case .closeTab: "close_tab"
        case .renamePane: "rename_pane"
        case .editScrollback: "edit_scrollback"
        case .copyMode: "copy_mode"
        case .focusPane(let direction): "focus_pane_\(direction.configSuffix)"
        case .swapPane(let direction): "swap_pane_\(direction.configSuffix)"
        case .lastPane: "last_pane"
        case .cyclePaneNext: "cycle_pane_next"
        case .cyclePanePrevious: "cycle_pane_previous"
        case .splitVertical: "split_vertical"
        case .splitHorizontal: "split_horizontal"
        case .closePane: "close_pane"
        case .zoom: "zoom"
        case .resizeMode: "resize_mode"
        case .resizePane(let direction): "resize_pane_\(direction.configSuffix)"
        case .toggleSidebar: "toggle_sidebar"
        case .command(let command): command.command
        }
    }
}

extension PaneDirection {
    fileprivate var configSuffix: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        }
    }
}
