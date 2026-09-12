import Foundation

public struct WorkspaceID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TabID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PaneID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Unrecognized wire values decode to `.unknown` rather than throwing, since
/// herdr may add statuses after this client is built.
public enum AgentStatus: String, Codable, Sendable {
    case idle, working, blocked, done, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

public struct CellRect: Codable, Equatable, Sendable {
    public let x, y, width, height: Int
}

public enum SplitDirection: String, Codable, Sendable {
    case right, down
}

public struct SplitInfo: Codable, Equatable, Sendable {
    public let id: String
    public let direction: SplitDirection
    public let ratio: Double
    public let rect: CellRect
}

public struct ScrollInfo: Codable, Equatable, Sendable {
    public let offsetFromBottom: Int
    public let maxOffsetFromBottom: Int
    public let viewportRows: Int

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }
}

public struct PaneRecord: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let workspaceID: WorkspaceID
    public let tabID: TabID
    public let focused: Bool
    public let agentStatus: AgentStatus
    public let revision: Int
    public let terminalTitleStripped: String?
    public let label: String?
    public let cwd: String
    public let scroll: ScrollInfo?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused
        case agentStatus = "agent_status"
        case revision
        case terminalTitleStripped = "terminal_title_stripped"
        case label
        case cwd
        case scroll
    }
}

public struct TabRecord: Codable, Equatable, Sendable {
    public let tabID: TabID
    public let workspaceID: WorkspaceID
    public var label: String
    public let number: Int
    public let paneCount: Int
    public let agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case label
        case number
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}

public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public var label: String
    public let number: Int
    public let activeTabID: TabID
    public let agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
        case number
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
    }
}

public struct PaneRect: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let focused: Bool
    public let rect: CellRect

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case focused
        case rect
    }
}

public struct LayoutSnapshot: Codable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let tabID: TabID
    public let zoomed: Bool
    public let area: CellRect
    public let focusedPaneID: PaneID?
    public var panes: [PaneRect]
    public let splits: [SplitInfo]

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case zoomed
        case area
        case focusedPaneID = "focused_pane_id"
        case panes
        case splits
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let focusedWorkspaceID: WorkspaceID?
    public let focusedTabID: TabID?
    public let focusedPaneID: PaneID?
    public let workspaces: [WorkspaceRecord]
    public let tabs: [TabRecord]
    public let panes: [PaneRecord]
    public let layouts: [LayoutSnapshot]

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces
        case tabs
        case panes
        case layouts
    }
}

/// The leaf payload of `layout.export`'s tree. Only the fields geometry
/// needs are decoded; `command`/`env` exist on the wire but have no reader
/// here.
public struct ExportedLayoutPane: Decodable, Equatable, Sendable {
    public let paneID: PaneID?
    public let label: String?
    public let cwd: String?

    public init(paneID: PaneID?, label: String? = nil, cwd: String? = nil) {
        self.paneID = paneID
        self.label = label
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case label
        case cwd
    }
}

/// `layout.export`'s split tree: a JSON `type`-tagged union (`"pane"` /
/// `"split"`) rather than the flat `splits` array `LayoutSnapshot` carries,
/// so nesting is the tree's own parent/child structure, never reconstructed
/// by rect containment. An unrecognized `type` throws during decode, which
/// callers must read as an unknown shape and fall back to rect derivation,
/// not as a crash.
public indirect enum ExportedLayoutNode: Decodable, Equatable, Sendable {
    case pane(ExportedLayoutPane)
    case split(direction: SplitDirection, ratio: Double, first: ExportedLayoutNode, second: ExportedLayoutNode)

    private enum CodingKeys: String, CodingKey {
        case type, direction, ratio, first, second
    }

    private enum NodeType: String, Decodable {
        case pane, split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .pane:
            self = .pane(try ExportedLayoutPane(from: decoder))
        case .split:
            self = .split(
                direction: try container.decode(SplitDirection.self, forKey: .direction),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(ExportedLayoutNode.self, forKey: .first),
                second: try container.decode(ExportedLayoutNode.self, forKey: .second)
            )
        }
    }
}

public struct ExportedLayoutDescription: Decodable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let tabID: TabID
    public let zoomed: Bool
    public let focusedPaneID: PaneID
    public let root: ExportedLayoutNode

    public init(workspaceID: WorkspaceID, tabID: TabID, zoomed: Bool, focusedPaneID: PaneID, root: ExportedLayoutNode) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.zoomed = zoomed
        self.focusedPaneID = focusedPaneID
        self.root = root
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case zoomed
        case focusedPaneID = "focused_pane_id"
        case root
    }
}

/// A tab's geometry-relevant fingerprint: area, pane set, and split
/// direction/ratio/rect, deliberately excluding focus and zoom so those
/// alone never trigger a `layout.export` refetch. Equal signatures mean the
/// coordinator's cached export (or its fallback flag) is still good for
/// this tab.
public struct LayoutTopologySignature: Equatable, Sendable {
    private let area: CellRect
    private let paneIDs: Set<PaneID>
    private let splits: [SplitInfo]

    public init(layout: LayoutSnapshot) {
        area = layout.area
        paneIDs = Set(layout.panes.map(\.paneID))
        splits = layout.splits
    }
}

public enum HerdrDecoder {
    private struct SnapshotResponse: Decodable {
        struct Result: Decodable {
            let snapshot: SessionSnapshot
        }
        let result: Result
    }

    public static func snapshot(fromResponseLine data: Data) throws -> SessionSnapshot {
        try JSONDecoder().decode(SnapshotResponse.self, from: data).result.snapshot
    }
}
