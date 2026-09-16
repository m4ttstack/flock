import Foundation

/// What an inline rename editor is currently open on. One editor at a time
/// per window, so `SessionViewModel` holds exactly one of these.
public enum RenameTarget: Hashable, Sendable {
    case pane(PaneID)
    case tab(TabID)
    case workspace(WorkspaceID)

    /// Whether `model` still carries what this editor is open on. An editor
    /// left open on something herdr has since closed has nothing to commit
    /// to, so the session closes it rather than hold the latch forever.
    public func exists(in model: SessionModel) -> Bool {
        switch self {
        case .pane(let pane):
            return model.panes[pane] != nil
        case .tab(let tab):
            return model.tabs.values.contains { $0.contains { $0.tabID == tab } }
        case .workspace(let workspace):
            return model.workspaces.contains { $0.workspaceID == workspace }
        }
    }
}

/// The rename editor's pure rules: what text it opens with, and which
/// `PrimitiveOp` (if any) a commit issues. No view, no herdr call.
///
/// A commit trims and then refuses three cases outright, returning `nil`:
/// a label that is empty once trimmed (herdr's `tab.rename`/`workspace.rename`
/// require a label, and clearing a PANE's manual name is its own menu command
/// rather than an empty commit), a label equal to the one already showing, and
/// a target the model no longer carries. Cancel has no rule of its own: the
/// view discards the text and nothing is issued.
public enum RenameEditor {
    /// The text the editor opens with -- a pane's MANUAL label only (empty
    /// when it has none, matching herdr's own pane-rename overlay, which
    /// never seeds the terminal title), and a tab's or workspace's own label.
    public static func initialText(for target: RenameTarget, model: SessionModel?) -> String {
        guard let model else { return "" }
        switch target {
        case .pane(let pane):
            return model.panes[pane]?.label ?? ""
        case .tab(let tab):
            return tabRecord(tab, model: model)?.label ?? ""
        case .workspace(let workspace):
            return model.workspaces.first { $0.workspaceID == workspace }?.label ?? ""
        }
    }

    public static func commit(_ text: String, for target: RenameTarget, model: SessionModel?) -> PrimitiveOp? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model else { return nil }
        switch target {
        case .pane(let pane):
            guard let record = model.panes[pane], record.label != trimmed else { return nil }
            return .renamePane(pane, trimmed)
        case .tab(let tab):
            guard let record = tabRecord(tab, model: model), record.label != trimmed else { return nil }
            return .renameTab(tab, trimmed)
        case .workspace(let workspace):
            guard let record = model.workspaces.first(where: { $0.workspaceID == workspace }), record.label != trimmed else { return nil }
            return .renameWorkspace(workspace, trimmed)
        }
    }

    /// The undo-journal label for a rename of this target, so undoing one
    /// reads as the thing that was renamed rather than a generic "Rename".
    public static func planLabel(for target: RenameTarget) -> String {
        switch target {
        case .pane: "Rename pane"
        case .tab: "Rename tab"
        case .workspace: "Rename workspace"
        }
    }

    private static func tabRecord(_ tab: TabID, model: SessionModel) -> TabRecord? {
        model.tabs.values.flatMap { $0 }.first { $0.tabID == tab }
    }
}
