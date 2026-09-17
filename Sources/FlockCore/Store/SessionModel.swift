import Foundation

public struct SessionModel: Equatable, Sendable {
    public var workspaces: [WorkspaceRecord]
    public var tabs: [WorkspaceID: [TabRecord]]
    public var panes: [PaneID: PaneRecord]
    public var layouts: [TabID: LayoutSnapshot]
    public var focusedWorkspaceID: WorkspaceID?
    public var focusedTabID: TabID?
    public var focusedPaneID: PaneID?

    public init(snapshot: SessionSnapshot) {
        workspaces = snapshot.workspaces

        var groupedTabs: [WorkspaceID: [TabRecord]] = [:]
        for tab in snapshot.tabs {
            groupedTabs[tab.workspaceID, default: []].append(tab)
        }
        tabs = groupedTabs

        var panesByID: [PaneID: PaneRecord] = [:]
        for pane in snapshot.panes {
            panesByID[pane.paneID] = pane
        }
        panes = panesByID

        var layoutsByTab: [TabID: LayoutSnapshot] = [:]
        for layout in snapshot.layouts {
            layoutsByTab[layout.tabID] = layout
        }
        layouts = layoutsByTab

        focusedWorkspaceID = snapshot.focusedWorkspaceID
        focusedTabID = snapshot.focusedTabID
        focusedPaneID = snapshot.focusedPaneID
    }
}
