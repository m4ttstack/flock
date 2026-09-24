import Foundation

extension SessionModel {
    /// The session without flock's own workspaces, which is the model every
    /// view reads: filtered once here, no surface can show them. Focus that
    /// sits inside one reads as none, so nothing that follows herdr's focus
    /// can follow it there.
    public var withoutFlockOwned: SessionModel {
        let hidden = Set(workspaces.filter { RtLabels.isFlockOwned(workspaceLabel: $0.label) }.map(\.workspaceID))
        guard !hidden.isEmpty else { return self }
        var visible = self
        let hiddenTabs = Set(hidden.flatMap { tabs[$0] ?? [] }.map(\.tabID))
        visible.workspaces.removeAll { hidden.contains($0.workspaceID) }
        for workspace in hidden { visible.tabs.removeValue(forKey: workspace) }
        visible.panes = panes.filter { !hidden.contains($0.value.workspaceID) }
        visible.layouts = layouts.filter { !hidden.contains($0.value.workspaceID) }
        if let workspace = focusedWorkspaceID, hidden.contains(workspace) {
            visible.focusedWorkspaceID = nil
        }
        if let tab = focusedTabID, hiddenTabs.contains(tab) {
            visible.focusedTabID = nil
        }
        if let pane = focusedPaneID, let record = panes[pane], hidden.contains(record.workspaceID) {
            visible.focusedPaneID = nil
        }
        return visible
    }
}
