import Foundation

/// One row of the pane context menu's "Move to..." submenu.
public struct MoveToEntry: Equatable, Sendable {
    public enum Group: Equatable, Sendable {
        case tabs
        case workspaces
        case create
    }

    public let label: String
    public let target: DropTarget
    public let accessibilityIdentifier: String
    public let group: Group
    /// The `WorkspaceIdentityStore` key whose symbol marks a workspace row;
    /// nil for a tab or a create row.
    public let identityKey: String?

    public init(label: String, target: DropTarget, accessibilityIdentifier: String, group: Group, identityKey: String? = nil) {
        self.label = label
        self.target = target
        self.accessibilityIdentifier = accessibilityIdentifier
        self.group = group
        self.identityKey = identityKey
    }
}

/// Pure menu-model builder for the pane context menu's move/swap commands --
/// no I/O, no herdr calls, just `SessionModel` in and rows out. The view
/// turns each entry into a `Button` that runs `SessionViewModel.perform(subject:target:)`.
public enum MoveToMenu {
    /// Every other tab in `pane`'s own workspace, then every other
    /// workspace, then "New Tab" and "New Workspace", in that order -- the
    /// pane's own tab is excluded (moving a pane into the tab it already
    /// occupies is not a gesture this menu offers). Empty when `pane` is not
    /// in `model` at all.
    ///
    /// With `sections`, workspaces are listed in rail order and named as the
    /// rail names them, empty rail pins included, and Board's review
    /// workspaces and the herds' are left out; without, in herdr's order.
    public static func entries(for pane: PaneID, model: SessionModel, sections: RailSections? = nil) -> [MoveToEntry] {
        guard let record = model.panes[pane] else { return [] }
        var entries: [MoveToEntry] = []

        for tab in model.tabs[record.workspaceID] ?? [] where tab.tabID != record.tabID {
            entries.append(MoveToEntry(
                label: TabTitle.resolve(tab, in: model).text,
                target: .tabThumbnail(tab.tabID),
                accessibilityIdentifier: "flock.pane.menu.moveTo.tab.\(tab.tabID.rawValue)",
                group: .tabs
            ))
        }
        for row in workspaceRows(model: model, sections: sections) where row.workspace != record.workspaceID {
            entries.append(MoveToEntry(
                label: row.label, target: row.target,
                accessibilityIdentifier: "flock.pane.menu.moveTo.workspace.\(row.identifier)",
                group: .workspaces, identityKey: row.identityKey
            ))
        }
        entries.append(MoveToEntry(
            label: "New Tab",
            target: .newTab(record.workspaceID),
            accessibilityIdentifier: "flock.pane.menu.moveTo.newTab.\(record.workspaceID.rawValue)",
            group: .create
        ))
        entries.append(MoveToEntry(
            label: "New Workspace",
            target: .newWorkspace,
            accessibilityIdentifier: "flock.pane.menu.moveTo.newWorkspace.new",
            group: .create
        ))
        return entries
    }

    private struct WorkspaceRow {
        let workspace: WorkspaceID?
        let label: String
        let target: DropTarget
        let identifier: String
        let identityKey: String?
    }

    private static func workspaceRows(model: SessionModel, sections: RailSections?) -> [WorkspaceRow] {
        func row(_ record: WorkspaceRecord, label: String? = nil, key: String?) -> WorkspaceRow {
            WorkspaceRow(
                workspace: record.workspaceID, label: label ?? record.label, target: .workspaceThumbnail(record.workspaceID),
                identifier: record.workspaceID.rawValue, identityKey: key
            )
        }
        guard let sections else {
            return model.workspaces.map { row($0, key: $0.workspaceID.rawValue) }
        }
        let setAside = sections.reviewIDs.union(sections.herdIDs)
        var rows: [WorkspaceRow] = sections.pinned.compactMap { pinned in
            guard let record = pinned.record else {
                return WorkspaceRow(
                    workspace: nil, label: pinned.pin.name, target: .emptyPin(pinned.pin.id),
                    identifier: pinned.pin.identityKey, identityKey: pinned.pin.identityKey
                )
            }
            guard !setAside.contains(record.workspaceID) else { return nil }
            return row(record, label: pinned.pin.name, key: pinned.pin.identityKey)
        }
        rows += sections.workspaces.filter { !setAside.contains($0.workspaceID) }.map { row($0, key: $0.workspaceID.rawValue) }
        return rows
    }

    /// The swap target for `pane`'s own "Swap with Focused Pane" menu item,
    /// or `nil` when there is nothing to offer: `pane` IS the
    /// resolved-focused pane (herdr parity: a pane never swaps with itself),
    /// or the focused pane is in a DIFFERENT tab. `resolvedFocusedPaneID` is
    /// herdr's GLOBAL focus, not scoped to `pane`'s own tab -- without the
    /// same-tab check, this would plan a cross-tab MOVE (`GesturePlanner`'s
    /// `paneInterior` cross-tab rule) under a "Swap" label whenever focus
    /// happened to be elsewhere.
    public static func swapTarget(for pane: PaneID, focusedPane: PaneID?, model: SessionModel) -> DropTarget? {
        guard let focusedPane, focusedPane != pane,
              let focusedTab = model.panes[focusedPane]?.tabID,
              let paneTab = model.panes[pane]?.tabID,
              focusedTab == paneTab
        else { return nil }
        return .paneInterior(focusedPane)
    }
}
