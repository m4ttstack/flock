import Foundation

/// One pane as mission control draws it.
public struct MissionCard: Equatable, Sendable, Identifiable {
    public var id: PaneID { paneID }
    public let paneID: PaneID
    public let workspaceID: WorkspaceID
    public let tabID: TabID
    /// A herd's workspace reads "auth-sweep · herd 2/4".
    public let workspaceName: String
    public let tabTitle: String
    public let title: String
    public let status: AgentStatus
    /// When the pane entered `status`, or when its attention card was raised.
    public let since: Date?
    public let folder: String
}

public struct MissionGroup: Equatable, Sendable, Identifiable {
    public var id: WorkspaceID { workspaceID }
    public let workspaceID: WorkspaceID
    public let name: String
    public let cards: [MissionCard]
}

/// Every pane in the lane its state puts it in. Needs you is the attention
/// stack itself, so the dock and the lane can never disagree.
public struct MissionBoard: Equatable, Sendable {
    public let needsYou: [MissionCard]
    public let working: [MissionGroup]
    public let coolingDown: [MissionCard]
    public let dormant: [MissionCard]
    public let dormantWorkspaces: Set<WorkspaceID>

    /// The drawn lanes, top to bottom, for the keyboard.
    public var columns: [[PaneID]] {
        [needsYou.map(\.paneID), working.flatMap(\.cards).map(\.paneID), coolingDown.map(\.paneID)]
    }

    public init(
        model: SessionModel, sections: RailSections, toasts: AttentionToastStack,
        history: PaneStatusHistory, cutoff: TimeInterval, now: Date
    ) {
        let railOrder = sections.workspaces.map(\.workspaceID) + sections.board.map(\.workspaceID)
            + sections.herds.map(\.workspaceID)
        let rank = Dictionary(railOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [WorkspaceID: String] = Dictionary(model.workspaces.map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
        for herd in sections.herds {
            names[herd.workspaceID] = "\(herd.name) · herd \(herd.done)/\(herd.total)"
        }

        func card(_ pane: PaneRecord, status: AgentStatus, since: Date?) -> MissionCard {
            let tab = model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }
            return MissionCard(
                paneID: pane.paneID, workspaceID: pane.workspaceID, tabID: pane.tabID,
                workspaceName: names[pane.workspaceID] ?? pane.workspaceID.rawValue,
                tabTitle: tab.map { TabTitle.resolve($0, in: model).text } ?? pane.tabID.rawValue,
                title: pane.displayTitle, status: status, since: since,
                folder: pane.foregroundCwd ?? pane.cwd
            )
        }

        func railKey(_ pane: PaneRecord) -> (Int, Int, String) {
            let tabIndex = model.tabs[pane.workspaceID]?.firstIndex { $0.tabID == pane.tabID } ?? Int.max
            return (rank[pane.workspaceID] ?? Int.max, tabIndex, pane.paneID.rawValue)
        }

        let toasted = Set(toasts.toasts.map(\.paneID))
        needsYou = toasts.toasts.reversed().compactMap { toast in
            model.panes[toast.paneID].map { card($0, status: toast.status, since: toast.raisedAt) }
        }

        var working: [PaneRecord] = []
        var cooling: [(PaneRecord, Date?)] = []
        var dormant: [PaneRecord] = []
        for pane in model.panes.values where !toasted.contains(pane.paneID) {
            if pane.agentStatus == .working {
                working.append(pane)
            } else if let age = history.age(of: pane.paneID, at: now), age <= cutoff {
                cooling.append((pane, history.lastChange(of: pane.paneID)))
            } else {
                dormant.append(pane)
            }
        }

        var groups: [MissionGroup] = []
        for pane in working.sorted(by: { railKey($0) < railKey($1) }) {
            let next = card(pane, status: .working, since: history.lastChange(of: pane.paneID))
            if let last = groups.last, last.workspaceID == pane.workspaceID {
                groups[groups.count - 1] = MissionGroup(workspaceID: last.workspaceID, name: last.name, cards: last.cards + [next])
            } else {
                groups.append(MissionGroup(workspaceID: pane.workspaceID, name: next.workspaceName, cards: [next]))
            }
        }
        self.working = groups
        coolingDown = cooling
            .sorted { ($0.1 ?? .distantPast, $1.0.paneID.rawValue) > ($1.1 ?? .distantPast, $0.0.paneID.rawValue) }
            .map { card($0.0, status: $0.0.agentStatus, since: $0.1) }
        self.dormant = dormant.sorted { railKey($0) < railKey($1) }
            .map { card($0, status: $0.agentStatus, since: history.lastChange(of: $0.paneID)) }

        let dormantIDs = Set(dormant.map(\.paneID))
        var byWorkspace: [WorkspaceID: [PaneID]] = [:]
        for pane in model.panes.values { byWorkspace[pane.workspaceID, default: []].append(pane.paneID) }
        dormantWorkspaces = Set(byWorkspace.filter { !$0.value.isEmpty && $0.value.allSatisfy(dormantIDs.contains) }.keys)
    }
}

public enum MissionSelection {
    public enum Direction: Sendable { case up, down, left, right }

    /// Up and down stay in a lane; left and right go to the nearest row of the
    /// next lane that has cards. With nothing selected, the first card.
    public static func move(_ selection: PaneID?, _ direction: Direction, in columns: [[PaneID]]) -> PaneID? {
        guard let selection,
              let column = columns.firstIndex(where: { $0.contains(selection) }),
              let row = columns[column].firstIndex(of: selection)
        else { return columns.first { !$0.isEmpty }?.first }
        switch direction {
        case .up: return columns[column][max(0, row - 1)]
        case .down: return columns[column][min(columns[column].count - 1, row + 1)]
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var next = column + step
            while columns.indices.contains(next) {
                if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                next += step
            }
            return selection
        }
    }
}

public enum MissionAge {
    public static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
