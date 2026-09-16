import Foundation

/// What the rename key (F2) opens the editor on, given what the window
/// currently has selected. The decision is here rather than in the menu
/// handler so it can be pinned by a test; the app's only job is to bind the
/// key and hand over the three ids.
public enum RenameShortcut {
    /// Innermost selection wins: the focused pane, else the selected tab,
    /// else the selected workspace. That is the order the surfaces nest in,
    /// so the key always renames the most specific thing on screen -- and the
    /// only thing a double-click on that same surface would have renamed.
    /// `nil` when nothing is selected at all, which leaves the menu item
    /// disabled rather than opening an editor on nothing.
    public static func target(
        focusedPane: PaneID?, selectedTab: TabID?, selectedWorkspace: WorkspaceID?
    ) -> RenameTarget? {
        if let focusedPane { return .pane(focusedPane) }
        if let selectedTab { return .tab(selectedTab) }
        if let selectedWorkspace { return .workspace(selectedWorkspace) }
        return nil
    }
}
