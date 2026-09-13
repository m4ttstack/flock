import Foundation

/// One row of the pane context menu's "Move to..." submenu.
public struct MoveToEntry: Equatable, Sendable {
    public let label: String
    public let target: DropTarget
    public let accessibilityIdentifier: String

    public init(label: String, target: DropTarget, accessibilityIdentifier: String) {
        self.label = label
        self.target = target
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// Pure menu-model builder for the pane context menu's move/swap commands --
/// no I/O, no herdr calls, just `SessionModel` in and rows out. The view
/// turns each entry into a `Button` that runs `SessionViewModel.perform(subject:target:)`.
public enum MoveToMenu {
    /// Every other tab in `pane`'s own workspace, then every other
    /// workspace, then "New Tab" and "New Workspace", in that order -- the
    /// pane's own tab is excluded (moving a pane into the tab it already
    /// occupies is not a gesture this menu offers). Empty when `pane` is not
    /// in `model` at all.
    public static func entries(for pane: PaneID, model: SessionModel) -> [MoveToEntry] {
        guard let record = model.panes[pane] else { return [] }
        var entries: [MoveToEntry] = []

        for tab in model.tabs[record.workspaceID] ?? [] where tab.tabID != record.tabID {
            entries.append(MoveToEntry(
                label: "Tab: \(tab.label)",
                target: .tabThumbnail(tab.tabID),
                accessibilityIdentifier: "paddock.pane.menu.moveTo.tab.\(tab.tabID.rawValue)"
            ))
        }
        for workspace in model.workspaces where workspace.workspaceID != record.workspaceID {
            entries.append(MoveToEntry(
                label: "Workspace: \(workspace.label)",
                target: .workspaceThumbnail(workspace.workspaceID),
                accessibilityIdentifier: "paddock.pane.menu.moveTo.workspace.\(workspace.workspaceID.rawValue)"
            ))
        }
        entries.append(MoveToEntry(
            label: "New Tab",
            target: .newTab(record.workspaceID),
            accessibilityIdentifier: "paddock.pane.menu.moveTo.newTab.\(record.workspaceID.rawValue)"
        ))
        entries.append(MoveToEntry(
            label: "New Workspace",
            target: .newWorkspace,
            accessibilityIdentifier: "paddock.pane.menu.moveTo.newWorkspace.new"
        ))
        return entries
    }

    /// The swap target for `pane`'s own "Swap with Focused Pane" menu item,
    /// or `nil` when there is nothing to offer: `pane` IS the
    /// resolved-focused pane (herdr parity: a pane never swaps with itself),
    /// or the focused pane is in a DIFFERENT tab. `resolvedFocusedPaneID` is
    /// herdr's GLOBAL focus, not scoped to `pane`'s own tab -- without the
    /// same-tab check, this would plan a cross-tab MOVE (`GesturePlanner`'s
    /// `paneInterior` cross-tab rule) under a "Swap" label whenever focus
    /// happened to be elsewhere.
    public static func swapTarget(for pane: PaneID, focusedPane: PaneID?, model: SessionModel) -> DropTarget? {
        guard let focusedPane, focusedPane != pane,
              let focusedTab = model.panes[focusedPane]?.tabID,
              let paneTab = model.panes[pane]?.tabID,
              focusedTab == paneTab
        else { return nil }
        return .paneInterior(focusedPane)
    }
}
