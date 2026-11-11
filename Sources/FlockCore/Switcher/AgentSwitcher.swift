import Foundation

public typealias AgentSwitcher = RecentsSwitcher<PaneID>

extension RecentsSwitcher where ID == PaneID {
    public static var defaultsKey: String { "flock.agentRecents" }

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(defaultsKey: Self.defaultsKey, userDefaults: userDefaults)
    }

    /// Every pane herdr found an agent in, across all workspaces: in the
    /// rail's workspace order, then tab order, then pane id.
    public static func candidates(in model: SessionModel) -> [PaneID] {
        let workspaceRank = Dictionary(
            model.workspaces.enumerated().map { ($1.workspaceID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let tabRank = Dictionary(
            model.tabs.values.flatMap { $0 }.map { ($0.tabID, $0.number) }, uniquingKeysWith: { first, _ in first }
        )
        return model.panes.values
            .filter { $0.agent != nil }
            .sorted { a, b in
                let keyA = (workspaceRank[a.workspaceID] ?? .max, tabRank[a.tabID] ?? .max, a.paneID.rawValue)
                let keyB = (workspaceRank[b.workspaceID] ?? .max, tabRank[b.tabID] ?? .max, b.paneID.rawValue)
                return keyA < keyB
            }
            .map(\.paneID)
    }

    /// Where the agent lives, for the row's right side: its workspace, and
    /// its tab when the workspace has more than one.
    public static func location(of pane: PaneRecord, in model: SessionModel) -> String? {
        guard let workspace = model.workspaces.first(where: { $0.workspaceID == pane.workspaceID }) else { return nil }
        let tabs = model.tabs[pane.workspaceID] ?? []
        guard tabs.count > 1, let tab = tabs.first(where: { $0.tabID == pane.tabID }) else { return workspace.label }
        return "\(workspace.label) · \(TabSwitcher.title(for: tab, in: model))"
    }
}
