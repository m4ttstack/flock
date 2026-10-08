import Foundation

/// The workspace rail's three lists: the workspaces a person arranges, the
/// ones the board app launches into, and the herds a shepherd watches.
///
/// Only the first list is the rail's to reorder. Board targets its
/// workspaces by label and rt names each herd's, so neither may be renamed
/// or moved from the rail.
public struct RailSections: Equatable, Sendable {
    public struct PinnedRow: Equatable, Sendable {
        public let pin: PinnedWorkspace
        /// The linked workspace, nil for an empty pin.
        public let record: WorkspaceRecord?
    }

    /// Rail pins only; a top-bar pin is in `topBar`.
    public let pinned: [PinnedRow]
    /// Drawn in the title bar, never in the rail.
    public let topBar: [PinnedRow]
    public let workspaces: [WorkspaceRecord]
    /// In role order, then herdr's order within a role.
    public let board: [WorkspaceRecord]
    public let herds: [HerdRail.Herd]
    public let herdSummary: HerdRail.Summary?

    /// Board's review workspaces and the herds' own, which Arrange leaves out
    /// and Overview leaves out unless asked for.
    public var reviewIDs: Set<WorkspaceID> { Set(board.map(\.workspaceID)) }
    public var herdIDs: Set<WorkspaceID> { Set(herds.map(\.workspaceID)) }

    /// Board is drawn from what `HerdRail` leaves, so a label that names both
    /// a herd and a board role is the herd's. A workspace linked to a pin
    /// shows in that pin's row alone: PINNED for a rail pin, the title bar
    /// for a top-bar one.
    public init(
        model: SessionModel, board names: BoardWorkspaceNames?, herdProgress: [String: HerdProgress] = [:],
        pins: [PinnedWorkspace] = [], topBarModel: SessionModel? = nil
    ) {
        let herdRail = HerdRail(model: model, progress: herdProgress)
        let labels = names?.labels ?? []
        var records: [WorkspaceID: WorkspaceRecord] = [:]
        for record in model.workspaces where records[record.workspaceID] == nil { records[record.workspaceID] = record }
        var barRecords: [WorkspaceID: WorkspaceRecord] = [:]
        for record in (topBarModel ?? model).workspaces where barRecords[record.workspaceID] == nil {
            barRecords[record.workspaceID] = record
        }
        pinned = pins.filter { $0.placement == .rail }.map { PinnedRow(pin: $0, record: $0.workspace.flatMap { records[$0] }) }
        topBar = pins.filter { $0.placement == .topBar }.map { PinnedRow(pin: $0, record: $0.workspace.flatMap { barRecords[$0] }) }
        let linked = Set((pinned + topBar).compactMap { $0.record?.workspaceID })
        workspaces = herdRail.workspaces.filter { !labels.contains($0.label) && !linked.contains($0.workspaceID) }
        board = labels.flatMap { label in herdRail.workspaces.filter { $0.label == label && !linked.contains($0.workspaceID) } }
        herds = herdRail.herds.filter { !linked.contains($0.workspaceID) }
        herdSummary = HerdRail.summary(of: herds)
    }

    /// Every workspace in the order the rail draws its sections, folded or not.
    public var railOrder: [WorkspaceID] {
        pinned.compactMap { $0.record?.workspaceID }
            + workspaces.map(\.workspaceID) + board.map(\.workspaceID) + herds.map(\.workspaceID)
    }

    /// One row of the rail as the keyboard walks it.
    public struct Row: Equatable, Sendable {
        public let workspaceID: WorkspaceID
        public let title: String
    }

    /// The rows top to bottom as the rail draws them, so a folded section's
    /// rows are skipped the way the eye skips them.
    public func navigationOrder(isCollapsed: (RailSection) -> Bool) -> [Row] {
        var rows = pinned.compactMap { row in row.record.map { Row(workspaceID: $0.workspaceID, title: row.pin.name) } }
        rows += workspaces.map { Row(workspaceID: $0.workspaceID, title: $0.label) }
        if !isCollapsed(.board) { rows += board.map { Row(workspaceID: $0.workspaceID, title: $0.label) } }
        if !isCollapsed(.herds) { rows += herds.map { Row(workspaceID: $0.workspaceID, title: $0.name) } }
        return rows
    }

    public static func isRailRow(label: String, board: BoardWorkspaceNames?) -> Bool {
        !HerdWorkspace.isHerd(label: label) && !(board?.contains(label: label) ?? false)
            && !RtLabels.isFlockOwned(workspaceLabel: label)
    }

    /// The dot a folded Board header shows: the loudest of its workspaces by
    /// herdr's own attention order, and only while that is an active state.
    /// An open section shows none, because its rows carry their own.
    public static func boardHeaderStatus(for board: [WorkspaceRecord], isCollapsed: Bool) -> AgentStatus? {
        guard isCollapsed else { return nil }
        let loudest = AgentAttention.aggregate(board.map(\.agentStatus))
        switch loudest {
        case .working, .blocked, .done: return loudest
        case .idle, .unknown: return nil
        }
    }

    /// The rail reorders its own rows among themselves, and herdr's
    /// `workspace.move` takes an index into its full list, Board's workspaces
    /// and herds included. A slot before the rail's `railIndex`th row lands
    /// before that same workspace; a slot past the last row lands just after
    /// the last one. Pinned workspaces sit in PINNED, outside the rows this
    /// index counts.
    public static func modelInsertIndex(
        forRailIndex railIndex: Int, in model: SessionModel, board: BoardWorkspaceNames?, pinned: Set<WorkspaceID> = []
    ) -> Int {
        let railIndices = model.workspaces.indices.filter {
            isRailRow(label: model.workspaces[$0].label, board: board) && !pinned.contains(model.workspaces[$0].workspaceID)
        }
        if railIndex < railIndices.count {
            return railIndices[max(railIndex, 0)]
        }
        return (railIndices.last.map { $0 + 1 }) ?? railIndex
    }
}
