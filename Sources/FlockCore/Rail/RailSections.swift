import Foundation

/// The workspace rail's three lists: the workspaces a person arranges, the
/// ones the board app launches into, and the herds a shepherd watches.
///
/// Only the first list is the rail's to reorder. Board targets its
/// workspaces by label and rt names each herd's, so neither may be renamed
/// or moved from the rail.
public struct RailSections: Equatable, Sendable {
    public let workspaces: [WorkspaceRecord]
    /// In role order, then herdr's order within a role.
    public let board: [WorkspaceRecord]
    public let herds: [HerdRail.Herd]
    public let herdSummary: HerdRail.Summary?

    /// Board is drawn from what `HerdRail` leaves, so a label that names both
    /// a herd and a board role is the herd's.
    public init(model: SessionModel, board names: BoardWorkspaceNames?, herdProgress: [String: HerdProgress] = [:]) {
        let herdRail = HerdRail(model: model, progress: herdProgress)
        let labels = names?.labels ?? []
        workspaces = herdRail.workspaces.filter { !labels.contains($0.label) }
        board = labels.flatMap { label in herdRail.workspaces.filter { $0.label == label } }
        herds = herdRail.herds
        herdSummary = herdRail.summary
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
    /// the last one.
    public static func modelInsertIndex(forRailIndex railIndex: Int, in model: SessionModel, board: BoardWorkspaceNames?) -> Int {
        let railIndices = model.workspaces.indices.filter { isRailRow(label: model.workspaces[$0].label, board: board) }
        if railIndex < railIndices.count {
            return railIndices[max(railIndex, 0)]
        }
        return (railIndices.last.map { $0 + 1 }) ?? railIndex
    }
}
