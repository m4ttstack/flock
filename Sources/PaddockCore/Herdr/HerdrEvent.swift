import Foundation

public struct PaneMovedPayload: Sendable {
    public let previousPaneID: PaneID
    public let previousWorkspaceID: WorkspaceID
    public let previousTabID: TabID
    public let pane: PaneRecord
    public let createdTab: TabRecord?
    public let createdWorkspace: WorkspaceRecord?
    public let closedTabID: TabID?
    public let closedWorkspaceID: WorkspaceID?
}

public enum HerdrEvent: Sendable {
    case layoutUpdated(LayoutSnapshot)
    case paneCreated(PaneRecord)
    case paneUpdated(PaneRecord)
    case paneClosed(PaneID)
    case paneFocused(PaneID)
    case paneMoved(PaneMovedPayload)
    case paneExited(PaneID)
    case paneAgentStatusChanged(PaneID, AgentStatus)
    /// Never arrives on the blanket subscription: it is pane-scoped, fed by
    /// one `pane.scroll_changed` subscription per attached pane
    /// (`PaneScrollSubscriber`) and decoded by `HerdrDecoder.scrollChanged`.
    case paneScrollChanged(PaneID, ScrollInfo)
    case tabCreated(TabRecord)
    case tabClosed(TabID)
    case tabRenamed(TabID, String)
    case tabMoved(TabID, WorkspaceID, [TabRecord])
    case tabFocused(TabID)
    case workspaceCreated(WorkspaceRecord)
    case workspaceClosed(WorkspaceID)
    case workspaceRenamed(WorkspaceID, String)
    case workspaceMoved([WorkspaceRecord])
    case workspaceReordered([WorkspaceRecord])
    case workspaceFocused(WorkspaceID)
    case unknown(type: String)
}

extension HerdrDecoder {
    /// Every field optional: one payload shape serves every event type, and a
    /// case whose fields don't decode falls through to `.unknown` rather than throwing.
    private struct EventPayload: Decodable {
        let type: String
        let layout: LayoutSnapshot?
        let pane: PaneRecord?
        let tab: TabRecord?
        let workspace: WorkspaceRecord?
        let workspaces: [WorkspaceRecord]?
        let tabs: [TabRecord]?
        let paneID: PaneID?
        let workspaceID: WorkspaceID?
        let tabID: TabID?
        let label: String?
        let agentStatus: AgentStatus?
        let previousPaneID: PaneID?
        let previousWorkspaceID: WorkspaceID?
        let previousTabID: TabID?
        let createdTab: TabRecord?
        let createdWorkspace: WorkspaceRecord?
        let closedTabID: TabID?
        let closedWorkspaceID: WorkspaceID?

        enum CodingKeys: String, CodingKey {
            case type, layout, pane, tab, workspace, workspaces, tabs, label
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case agentStatus = "agent_status"
            case previousPaneID = "previous_pane_id"
            case previousWorkspaceID = "previous_workspace_id"
            case previousTabID = "previous_tab_id"
            case createdTab = "created_tab"
            case createdWorkspace = "created_workspace"
            case closedTabID = "closed_tab_id"
            case closedWorkspaceID = "closed_workspace_id"
        }
    }

    private struct EventEnvelope: Decodable {
        struct Ack: Decodable {
            let type: String?
        }
        let data: EventPayload?
        let result: Ack?
    }

    /// The `{"event":"pane.scroll_changed","data":{...}}` frame a per-pane
    /// subscription connection streams -- a `SubscriptionEventEnvelope`, not
    /// the `EventEnvelope` shape `event(fromLine:)` reads (its `data` carries
    /// no `type`). `nil` for the subscribe ack and for every other line.
    public static func scrollChanged(fromLine line: Data) -> (paneID: PaneID, scroll: ScrollInfo)? {
        struct Payload: Decodable {
            let paneID: PaneID
            let scroll: ScrollInfo
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case scroll
            }
        }
        struct Envelope: Decodable {
            let event: String
            let data: Payload
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
              envelope.event == "pane.scroll_changed"
        else { return nil }
        return (envelope.data.paneID, envelope.data.scroll)
    }

    /// The scroll state in a `pane.get` response (`result.pane`), which is how
    /// the per-pane feed seeds itself: herdr's own `pane.scroll_changed`
    /// subscription probes at subscribe time and then emits only on a CHANGE,
    /// so nothing would ever report a pane that was already scrolled back.
    /// `nil` for an error response, a pane with no scroll state, and anything
    /// else.
    public static func scrollProbe(fromLine line: Data) -> (paneID: PaneID, scroll: ScrollInfo)? {
        struct Pane: Decodable {
            let paneID: PaneID
            let scroll: ScrollInfo?
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case scroll
            }
        }
        struct Result: Decodable { let pane: Pane }
        struct Envelope: Decodable { let result: Result }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
              let scroll = envelope.result.pane.scroll
        else { return nil }
        return (envelope.result.pane.paneID, scroll)
    }

    public static func event(fromLine line: Data) throws -> HerdrEvent {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: line)
        // Request/response acks (e.g. the subscribe confirmation) carry no
        // "data" field and have no dedicated case; surface them as unknown.
        guard let payload = envelope.data else {
            return .unknown(type: envelope.result?.type ?? "ack")
        }
        switch payload.type {
        case "layout_updated":
            guard let layout = payload.layout else { return .unknown(type: payload.type) }
            return .layoutUpdated(layout)
        case "pane_created":
            guard let pane = payload.pane else { return .unknown(type: payload.type) }
            return .paneCreated(pane)
        case "pane_updated":
            guard let pane = payload.pane else { return .unknown(type: payload.type) }
            return .paneUpdated(pane)
        case "pane_closed":
            guard let paneID = payload.paneID else { return .unknown(type: payload.type) }
            return .paneClosed(paneID)
        case "pane_focused":
            guard let paneID = payload.paneID else { return .unknown(type: payload.type) }
            return .paneFocused(paneID)
        case "pane_moved":
            guard let pane = payload.pane,
                  let previousPaneID = payload.previousPaneID,
                  let previousWorkspaceID = payload.previousWorkspaceID,
                  let previousTabID = payload.previousTabID
            else { return .unknown(type: payload.type) }
            return .paneMoved(PaneMovedPayload(
                previousPaneID: previousPaneID,
                previousWorkspaceID: previousWorkspaceID,
                previousTabID: previousTabID,
                pane: pane,
                createdTab: payload.createdTab,
                createdWorkspace: payload.createdWorkspace,
                closedTabID: payload.closedTabID,
                closedWorkspaceID: payload.closedWorkspaceID
            ))
        case "pane_exited":
            guard let paneID = payload.paneID else { return .unknown(type: payload.type) }
            return .paneExited(paneID)
        case "pane_agent_status_changed":
            guard let paneID = payload.paneID, let status = payload.agentStatus else {
                return .unknown(type: payload.type)
            }
            return .paneAgentStatusChanged(paneID, status)
        case "tab_created":
            guard let tab = payload.tab else { return .unknown(type: payload.type) }
            return .tabCreated(tab)
        case "tab_closed":
            guard let tabID = payload.tabID else { return .unknown(type: payload.type) }
            return .tabClosed(tabID)
        case "tab_renamed":
            guard let tabID = payload.tabID, let label = payload.label else {
                return .unknown(type: payload.type)
            }
            return .tabRenamed(tabID, label)
        case "tab_moved":
            guard let tabID = payload.tabID, let workspaceID = payload.workspaceID else {
                return .unknown(type: payload.type)
            }
            return .tabMoved(tabID, workspaceID, payload.tabs ?? [])
        case "tab_focused":
            guard let tabID = payload.tabID else { return .unknown(type: payload.type) }
            return .tabFocused(tabID)
        case "workspace_created":
            guard let workspace = payload.workspace else { return .unknown(type: payload.type) }
            return .workspaceCreated(workspace)
        case "workspace_closed":
            guard let workspaceID = payload.workspaceID else { return .unknown(type: payload.type) }
            return .workspaceClosed(workspaceID)
        case "workspace_renamed":
            guard let workspaceID = payload.workspaceID, let label = payload.label else {
                return .unknown(type: payload.type)
            }
            return .workspaceRenamed(workspaceID, label)
        case "workspace_moved":
            return .workspaceMoved(payload.workspaces ?? [])
        case "workspace_reordered":
            return .workspaceReordered(payload.workspaces ?? [])
        case "workspace_focused":
            guard let workspaceID = payload.workspaceID else { return .unknown(type: payload.type) }
            return .workspaceFocused(workspaceID)
        default:
            return .unknown(type: payload.type)
        }
    }
}
