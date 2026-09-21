import Foundation

/// What a close is aimed at. herdr's escalation is one ladder, pane to tab to
/// workspace, and these are the two rungs a flock verb enters it at.
public enum CloseSubject: Hashable, Sendable {
    case pane(PaneID)
    case tab(TabID)

    /// What the prompt calls the thing the user asked to close.
    var noun: String {
        switch self {
        case .pane: return "pane"
        case .tab: return "tab"
        }
    }
}

/// What a close is actually about to destroy. herdr escalates the verb on its
/// own: `Workspace::close_pane` (`src/workspace.rs`) removes the tab whose last
/// pane is leaving and reports the whole workspace closed when that tab was
/// also the workspace's last, and `handle_tab_close` (`src/app/api/tabs.rs`)
/// closes the workspace outright when the tab it is handed is the last one.
/// herdr's own request tests pin all three rungs
/// (`pane_close_request_closes_only_the_target_tab_when_other_tabs_exist`,
/// `pane_close_request_closes_workspace_when_it_removes_the_last_pane`,
/// `api_tab_close_last_tab_closes_workspace_and_emits_both_events`).
///
/// A close is irreversible in flock (`UndoJournal.describe`), so the escalated
/// rungs are the ones worth asking about; the common case, a pane among
/// siblings or a tab among tabs, is left instant and silent.
public enum CloseConsequence: Equatable, Sendable {
    /// The close takes what it names and no more.
    case subjectOnly
    /// `description` names the casualty the way the prompt says it aloud.
    case closesTab(description: String)
    case closesWorkspace(description: String)

    public static func of(_ subject: CloseSubject, model: SessionModel) -> CloseConsequence {
        switch subject {
        case .pane(let pane):
            guard let record = model.panes[pane] else { return .subjectOnly }
            guard !model.panes.values.contains(where: { $0.tabID == record.tabID && $0.paneID != pane }) else {
                return .subjectOnly
            }
            guard isLastTab(of: record.workspaceID, in: model) else {
                return .closesTab(description: describe(tab: record.tabID, in: model))
            }
            return .closesWorkspace(description: describe(workspace: record.workspaceID, in: model))
        case .tab(let tab):
            guard let workspaceID = workspace(holding: tab, in: model), isLastTab(of: workspaceID, in: model) else {
                return .subjectOnly
            }
            return .closesWorkspace(description: describe(workspace: workspaceID, in: model))
        }
    }

    /// The prompt to raise before closing `subject`, or `nil` when the close
    /// destroys nothing but what it names and interrupts nothing that is
    /// running.
    ///
    /// Two independent reasons to ask, and either alone is enough. The close
    /// escalates, which is what `casualty` answers, or it takes a pane that is
    /// mid-task, which is what `busy` answers. When both are true the prompt
    /// says both, because they are different losses: one destroys a container
    /// the user did not name, the other throws away work in progress.
    public func confirmation(closing subject: CloseSubject, busy: BusyPanes = .none) -> CloseConfirmation? {
        guard casualty != nil || !busy.isEmpty else { return nil }
        let escalation = casualty.map { _ in
            "This is its last \(subject.noun), so closing the \(subject.noun) closes \(taken(by: subject))."
        }
        let interruption = busy.sentence
        return CloseConfirmation(
            subject: subject,
            title: casualty.map { "Close \($0.description)?" } ?? "Close this \(subject.noun)?",
            message: ([escalation, interruption].compactMap { $0 } + ["A close cannot be undone."])
                .joined(separator: " "),
            confirmButtonTitle: casualty?.buttonTitle ?? "Close \(subject.noun.capitalized)"
        )
    }

    private var casualty: (description: String, buttonTitle: String)? {
        switch self {
        case .subjectOnly: return nil
        case .closesTab(let description): return (description, "Close Tab")
        case .closesWorkspace(let description): return (description, "Close Workspace")
        }
    }

    /// Everything the close takes, in the order it takes it. A pane that is its
    /// workspace's last names both rungs, since the tab going is what takes the
    /// workspace with it.
    private func taken(by subject: CloseSubject) -> String {
        switch (self, subject) {
        case (.closesWorkspace, .pane): return "the tab and the workspace with it"
        case (.closesWorkspace, .tab): return "the workspace"
        default: return "the tab"
        }
    }

    private static func isLastTab(of workspaceID: WorkspaceID, in model: SessionModel) -> Bool {
        (model.tabs[workspaceID]?.count ?? 0) <= 1
    }

    private static func workspace(holding tab: TabID, in model: SessionModel) -> WorkspaceID? {
        model.tabs.first { $0.value.contains { $0.tabID == tab } }?.key
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

    /// No position guard here, and deliberately: herdr labels a workspace with
    /// its custom name, else its cwd's own basename, else the bare word
    /// "workspace" (`Workspace::display_name_from` and `fallback_label_from_cwd`
    /// in `src/workspace/git/discovery.rs`). A workspace label is never its
    /// rail position, so reading one as a position would misread a workspace
    /// named for a directory that happens to match where it sits.
    private static func describe(workspace workspaceID: WorkspaceID, in model: SessionModel) -> String {
        guard let record = model.workspaces.first(where: { $0.workspaceID == workspaceID }) else {
            return "this workspace"
        }
        let label = record.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "workspace \(record.number)" : "the workspace \"\(label)\""
    }
}

/// One raised `CloseConsequence`, held while its prompt is on screen. It
/// carries the subject so the confirm button has what to close without a
/// second read, and the finished strings so the view branches on nothing.
public struct CloseConfirmation: Equatable, Identifiable, Sendable {
    public let subject: CloseSubject
    public let title: String
    public let message: String
    public let confirmButtonTitle: String

    public var id: CloseSubject { subject }

    public init(subject: CloseSubject, title: String, message: String, confirmButtonTitle: String) {
        self.subject = subject
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
    }
}
