import Foundation

/// Where flock's selection lands once a close has taken the tab, or the
/// workspace, it was sitting on. flock decides nothing of its own here: it
/// mirrors what herdr's own model already did, so the next snapshot agrees
/// with the window instead of jumping it somewhere else.
///
/// herdr's two rules are not the same rule. `Workspace::close_tab`
/// (`src/workspace.rs`) decrements `active_tab` whenever the closed tab sat
/// at or before it, so a closed tab hands selection to the tab on its LEFT,
/// and only the leftmost hands it rightward. `App::close_selected_workspace`
/// (`src/app/actions.rs`) keeps the closed workspace's own index and clamps
/// it to the last row, so a closed workspace hands selection to the row that
/// took its place, on its RIGHT, and only the last row hands it upward.
///
/// Stated here as "nearest survivor, this way first", which is herdr's own
/// answer for a single close and still answers when one burst of events takes
/// several neighbors at once.
public enum CloseSelection {
    /// flock's selected workspace and tab, in and out.
    public struct Selection: Equatable, Sendable {
        public let workspace: WorkspaceID?
        public let tab: TabID?

        public init(workspace: WorkspaceID?, tab: TabID?) {
            self.workspace = workspace
            self.tab = tab
        }
    }

    /// `before` is the model as it still carried what `selection` names;
    /// `after` is the model that no longer does. Anything `before` never
    /// carried is left alone: flock's own selection can name a tab herdr has
    /// not reported yet, and that is not a close.
    public static func landing(for selection: Selection, before: SessionModel, after: SessionModel) -> Selection {
        if let workspace = selection.workspace, wasClosed(workspace, before: before, after: after) {
            let landed = nearestSurvivor(
                of: workspace, in: before.workspaces.map(\.workspaceID),
                surviving: Set(after.workspaces.map(\.workspaceID)), searching: .rightward
            )
            return Selection(
                workspace: landed,
                tab: landed.flatMap { id in after.workspaces.first { $0.workspaceID == id }?.activeTabID }
            )
        }
        if let tab = selection.tab, let order = tabOrder(holding: tab, in: before), !carries(tab: tab, after) {
            return Selection(
                workspace: selection.workspace,
                tab: nearestSurvivor(of: tab, in: order, surviving: tabIDs(of: after), searching: .leftward)
            )
        }
        return selection
    }

    private enum SearchOrder {
        case leftward, rightward
    }

    /// The closest surviving id to `closed`'s own place in `order`, looked for
    /// one way and then the other. A neighbor that did not survive is stepped
    /// over rather than landed on.
    private static func nearestSurvivor<ID: Hashable>(
        of closed: ID, in order: [ID], surviving: Set<ID>, searching first: SearchOrder
    ) -> ID? {
        guard let index = order.firstIndex(of: closed) else { return nil }
        let leftward = order[..<index].reversed().first { surviving.contains($0) }
        let rightward = order[order.index(after: index)...].first { surviving.contains($0) }
        return first == .leftward ? (leftward ?? rightward) : (rightward ?? leftward)
    }

    private static func wasClosed(_ workspace: WorkspaceID, before: SessionModel, after: SessionModel) -> Bool {
        before.workspaces.contains { $0.workspaceID == workspace }
            && !after.workspaces.contains { $0.workspaceID == workspace }
    }

    /// The strip order of whichever workspace holds `tab`, which is not
    /// necessarily the selected one: a tab can be followed across a workspace
    /// boundary (`SessionViewModel.select(tab:)`).
    private static func tabOrder(holding tab: TabID, in model: SessionModel) -> [TabID]? {
        model.tabs.values.first { $0.contains { $0.tabID == tab } }?.map(\.tabID)
    }

    private static func carries(tab: TabID, _ model: SessionModel) -> Bool {
        model.tabs.values.contains { $0.contains { $0.tabID == tab } }
    }

    private static func tabIDs(of model: SessionModel) -> Set<TabID> {
        Set(model.tabs.values.flatMap { $0 }.map(\.tabID))
    }
}
