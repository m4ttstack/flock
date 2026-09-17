import Foundation

public func apply(_ event: HerdrEvent, to model: inout SessionModel) {
    switch event {
    case .layoutUpdated(let layout):
        model.layouts[layout.tabID] = layout

    case .paneCreated(let pane), .paneUpdated(let pane):
        model.panes[pane.paneID] = pane

    case .paneClosed(let paneID):
        let closed = model.panes.removeValue(forKey: paneID)
        for tabID in model.layouts.keys {
            model.layouts[tabID]?.panes.removeAll { $0.paneID == paneID }
        }
        if let closed {
            reaggregateAgentStatus(tab: closed.tabID, workspace: closed.workspaceID, in: &model)
        }

    case .paneFocused(let paneID):
        model.focusedPaneID = paneID
        // The tab's own focus field too: herdr computes it from the same
        // `tab.layout.focused()` this event reports, so a layout left naming
        // the previous pane is a snapshot herdr would never send. What reads
        // it is `CanvasComposition` -- the zoomed canvas follows focus, as
        // herdr's renderer does.
        if let tabID = model.panes[paneID]?.tabID {
            model.layouts[tabID]?.focusedPaneID = paneID
        }

    case .paneMoved(let payload):
        model.panes.removeValue(forKey: payload.previousPaneID)
        model.panes[payload.pane.paneID] = payload.pane
        if let createdTab = payload.createdTab {
            upsertTab(createdTab, into: &model)
        }
        if let createdWorkspace = payload.createdWorkspace {
            upsertWorkspace(createdWorkspace, into: &model)
        }
        if let closedTabID = payload.closedTabID {
            removeTab(closedTabID, from: &model)
        }
        if let closedWorkspaceID = payload.closedWorkspaceID {
            removeWorkspace(closedWorkspaceID, from: &model)
        }
        // Both ends, and after the structural changes: the source loses
        // whatever the moved pane was contributing, the destination gains it,
        // and a source that the move emptied has already been removed, which
        // the helper simply skips.
        reaggregateAgentStatus(tab: payload.previousTabID, workspace: payload.previousWorkspaceID, in: &model)
        reaggregateAgentStatus(tab: payload.pane.tabID, workspace: payload.pane.workspaceID, in: &model)

    case .paneScrollChanged(let paneID, let scroll):
        model.panes[paneID]?.scroll = scroll

    case .paneAgentStatusChanged(let paneID, let status):
        guard var pane = model.panes[paneID], pane.agentStatus != status else { break }
        pane.agentStatus = status
        model.panes[paneID] = pane
        reaggregateAgentStatus(tab: pane.tabID, workspace: pane.workspaceID, in: &model)

    case .paneExited:
        break

    case .tabCreated(let tab):
        upsertTab(tab, into: &model)

    case .tabClosed(let tabID):
        removeTab(tabID, from: &model)

    case .tabRenamed(let tabID, let label):
        for workspaceID in model.tabs.keys {
            guard let index = model.tabs[workspaceID]?.firstIndex(where: { $0.tabID == tabID }) else { continue }
            model.tabs[workspaceID]?[index].label = label
        }

    case .tabMoved(let tabID, let workspaceID, let tabs):
        for otherWorkspaceID in model.tabs.keys where otherWorkspaceID != workspaceID {
            model.tabs[otherWorkspaceID]?.removeAll { $0.tabID == tabID }
        }
        model.tabs[workspaceID] = tabs

    case .tabFocused(let tabID):
        model.focusedTabID = tabID

    case .workspaceCreated(let workspace):
        upsertWorkspace(workspace, into: &model)

    case .workspaceClosed(let workspaceID):
        removeWorkspace(workspaceID, from: &model)

    case .workspaceRenamed(let workspaceID, let label):
        guard let index = model.workspaces.firstIndex(where: { $0.workspaceID == workspaceID }) else { break }
        model.workspaces[index].label = label

    case .workspaceMoved(let workspaces), .workspaceReordered(let workspaces):
        model.workspaces = workspaces

    case .workspaceFocused(let workspaceID):
        model.focusedWorkspaceID = workspaceID

    case .unknown:
        break
    }
}

/// A snapshot is the only place herdr states a tab's or a workspace's own
/// agent status; a live frame names one pane. Without re-deriving them here
/// the strip and the rail would keep the status the session started with
/// while the pane they aggregate has moved on.
private func reaggregateAgentStatus(tab tabID: TabID, workspace workspaceID: WorkspaceID, in model: inout SessionModel) {
    let panes = model.panes.values
    if let index = model.tabs[workspaceID]?.firstIndex(where: { $0.tabID == tabID }) {
        model.tabs[workspaceID]?[index].agentStatus =
            AgentAttention.aggregate(panes.lazy.filter { $0.tabID == tabID }.map(\.agentStatus))
    }
    if let index = model.workspaces.firstIndex(where: { $0.workspaceID == workspaceID }) {
        model.workspaces[index].agentStatus =
            AgentAttention.aggregate(panes.lazy.filter { $0.workspaceID == workspaceID }.map(\.agentStatus))
    }
}

/// Create events are idempotent on the wire's id: a snapshot answered
/// concurrently with a buffered create for the same entity must not
/// duplicate it once the buffer replays.
private func upsertTab(_ tab: TabRecord, into model: inout SessionModel) {
    if let index = model.tabs[tab.workspaceID]?.firstIndex(where: { $0.tabID == tab.tabID }) {
        model.tabs[tab.workspaceID]?[index] = tab
    } else {
        model.tabs[tab.workspaceID, default: []].append(tab)
    }
}

private func upsertWorkspace(_ workspace: WorkspaceRecord, into model: inout SessionModel) {
    if let index = model.workspaces.firstIndex(where: { $0.workspaceID == workspace.workspaceID }) {
        model.workspaces[index] = workspace
    } else {
        model.workspaces.append(workspace)
    }
}

private func removeTab(_ tabID: TabID, from model: inout SessionModel) {
    for workspaceID in model.tabs.keys {
        model.tabs[workspaceID]?.removeAll { $0.tabID == tabID }
    }
    model.layouts.removeValue(forKey: tabID)
    // herdr's own `tab.close` emits only `TabClosed` -- no `PaneClosed`
    // for each of its panes -- so without this a closed tab's panes linger
    // in `model.panes` forever (and, downstream, their parked surfaces sit
    // in `SessionViewModel`'s warm pool until LRU eviction gets around to
    // them, rather than being torn down the moment the tab is actually
    // gone). Mirrors `removeWorkspace`'s own pane prune below.
    model.panes = model.panes.filter { $0.value.tabID != tabID }
}

private func removeWorkspace(_ workspaceID: WorkspaceID, from model: inout SessionModel) {
    model.workspaces.removeAll { $0.workspaceID == workspaceID }
    let removedTabs = model.tabs.removeValue(forKey: workspaceID) ?? []
    for tab in removedTabs {
        model.layouts.removeValue(forKey: tab.tabID)
    }
    model.panes = model.panes.filter { $0.value.workspaceID != workspaceID }
}
