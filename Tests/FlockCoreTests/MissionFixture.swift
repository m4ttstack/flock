import Foundation
@testable import FlockCore

/// Builds a `SessionModel` from a compact description. Workspace `w1` holds
/// tabs `w1:t1`, `w1:t2`...; tab `w1:t2` holds panes `w1:t2:p1`...
enum MissionFixture {
    struct Pane {
        let status: AgentStatus
        var title = "claude"
        var cwd = "/private/tmp"
    }

    struct Tab {
        let label: String
        let panes: [Pane]
    }

    struct Workspace {
        let label: String
        let tabs: [Tab]
    }

    static func model(_ specs: [Workspace], focusedPane: String? = nil) -> SessionModel {
        var workspaces: [WorkspaceRecord] = []
        var tabs: [TabRecord] = []
        var panes: [PaneRecord] = []
        for (w, spec) in specs.enumerated() {
            let workspaceID = WorkspaceID(rawValue: "w\(w + 1)")
            workspaces.append(WorkspaceRecord(
                workspaceID: workspaceID, label: spec.label, number: w + 1,
                activeTabID: TabID(rawValue: "w\(w + 1):t1"), agentStatus: .idle
            ))
            for (t, tab) in spec.tabs.enumerated() {
                let tabID = TabID(rawValue: "w\(w + 1):t\(t + 1)")
                tabs.append(TabRecord(
                    tabID: tabID, workspaceID: workspaceID, label: tab.label, number: t + 1,
                    paneCount: tab.panes.count, agentStatus: .idle
                ))
                for (p, pane) in tab.panes.enumerated() {
                    let paneID = PaneID(rawValue: "\(tabID.rawValue):p\(p + 1)")
                    panes.append(PaneRecord(
                        paneID: paneID, workspaceID: workspaceID, tabID: tabID,
                        focused: paneID.rawValue == focusedPane, agentStatus: pane.status, revision: 0,
                        terminalTitleStripped: pane.title, label: nil, cwd: pane.cwd, scroll: nil
                    ))
                }
            }
        }
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil,
            focusedPaneID: focusedPane.map(PaneID.init(rawValue:)),
            workspaces: workspaces, tabs: tabs, panes: panes, layouts: []
        ))
    }

    /// One workspace, one tab, one pane per status given.
    static func single(_ statuses: [AgentStatus], label: String = "acme") -> SessionModel {
        model([Workspace(label: label, tabs: [Tab(label: "main", panes: statuses.map { Pane(status: $0) })])])
    }
}
