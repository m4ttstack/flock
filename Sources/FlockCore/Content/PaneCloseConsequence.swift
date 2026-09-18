import Foundation

/// What a Close Pane is actually about to destroy. herdr escalates the verb
/// on its own: `Workspace::close_pane` (`src/workspace.rs`) removes the tab
/// whose last pane is leaving, and reports the whole workspace closed when
/// that tab was also the workspace's last. Its own request tests pin both
/// rungs (`pane_close_request_closes_only_the_target_tab_when_other_tabs_exist`
/// and `pane_close_request_closes_workspace_when_it_removes_the_last_pane`).
///
/// A close is irreversible in flock (`UndoJournal.describe`), so the escalated
/// rungs are the ones worth asking about; the common case, one pane among
/// several, is left instant and silent.
public enum PaneCloseConsequence: Equatable, Sendable {
    /// The tab holds other panes, so the close takes the pane and no more.
    case paneOnly
    /// `description` names the tab the way the confirmation says it aloud.
    case closesTab(description: String)
    case closesWorkspace(description: String)

    public static func of(pane: PaneID, model: SessionModel) -> PaneCloseConsequence {
        guard let record = model.panes[pane] else { return .paneOnly }
        guard !model.panes.values.contains(where: { $0.tabID == record.tabID && $0.paneID != pane }) else {
            return .paneOnly
        }
        guard (model.tabs[record.workspaceID]?.count ?? 0) <= 1 else {
            return .closesTab(description: describe(tab: record.tabID, in: model))
        }
        return .closesWorkspace(description: describe(workspace: record.workspaceID, in: model))
    }

    /// The prompt to raise before closing `pane`, or `nil` when the close
    /// destroys nothing but the pane itself.
    public func confirmation(closing pane: PaneID) -> PaneCloseConfirmation? {
        switch self {
        case .paneOnly:
            return nil
        case .closesTab(let description):
            return PaneCloseConfirmation(
                paneID: pane,
                title: "Close \(description)?",
                message: "This is its last pane, so closing the pane closes the tab. A close cannot be undone.",
                confirmButtonTitle: "Close Tab"
            )
        case .closesWorkspace(let description):
            return PaneCloseConfirmation(
                paneID: pane,
                title: "Close \(description)?",
                message: "This is its last pane, so closing the pane closes the tab and the workspace with it. "
                    + "A close cannot be undone.",
                confirmButtonTitle: "Close Workspace"
            )
        }
    }

    /// herdr reports a tab nobody has renamed as its own 1-based position, so
    /// `carriedName` returning nil means the label IS that position and the
    /// prompt says it as one rather than quoting a number as a name.
    private static func describe(tab tabID: TabID, in model: SessionModel) -> String {
        guard let record = model.tabs.values.flatMap({ $0 }).first(where: { $0.tabID == tabID }) else {
            return "this tab"
        }
        guard let name = carriedName(ofTab: tabID, model: model) else { return "tab \(record.label)" }
        return "the tab \"\(name)\""
    }

    private static func describe(workspace workspaceID: WorkspaceID, in model: SessionModel) -> String {
        guard let record = model.workspaces.first(where: { $0.workspaceID == workspaceID }) else {
            return "this workspace"
        }
        let label = record.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "workspace \(record.number)" : "the workspace \"\(label)\""
    }
}

/// One raised `PaneCloseConsequence`, held while its prompt is on screen. It
/// carries the pane so the confirm button has the id to close without a
/// second read, and the finished strings so the view branches on nothing.
public struct PaneCloseConfirmation: Equatable, Identifiable, Sendable {
    public let paneID: PaneID
    public let title: String
    public let message: String
    public let confirmButtonTitle: String

    public var id: PaneID { paneID }

    public init(paneID: PaneID, title: String, message: String, confirmButtonTitle: String) {
        self.paneID = paneID
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
    }
}
