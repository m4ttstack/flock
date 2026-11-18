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

    public static func workspace(of subject: CloseSubject, in model: SessionModel) -> WorkspaceID? {
        switch subject {
        case .pane(let pane): model.panes[pane]?.workspaceID
        case .tab(let tab): workspace(holding: tab, in: model)
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
    public func confirmation(
        closing subject: CloseSubject, busy: BusyPanes = .none, agents: AgentSessions = .none, subjectName: String? = nil
    ) -> CloseConfirmation? {
        guard casualty != nil || !busy.isEmpty || !agents.isEmpty else { return nil }
        // A close that escalates is named for what it really takes.
        let noun = casualtyNoun ?? subject.noun
        let name = casualty?.description ?? subjectName
        let parts = Self.headingParts(noun: noun, name: name)
        return CloseConfirmation(
            subject: subject,
            title: Self.heading(noun: noun, name: name),
            action: parts.action,
            name: parts.name,
            message: summary(closing: subject, noun: noun, busy: busy, agents: agents),
            confirmButtonTitle: casualty?.buttonTitle ?? "Close \(subject.noun.capitalized)",
            warnsOfAgents: !agents.isEmpty
        )
    }

    /// The prompt's longest name before it is cut short.
    static let nameLimit = 40

    /// The action and the name the prompt shows apart from it. A tab herdr
    /// only numbers keeps its number in the action: a place, not a name.
    static func headingParts(noun: String, name: String?) -> (action: String, name: String?) {
        let Noun = noun.prefix(1).uppercased() + noun.dropFirst()
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return ("Close \(Noun)", nil) }
        if TabTitle.isAutoNamed(name) { return ("Close \(Noun) \(name)", nil) }
        return ("Close \(Noun)", name)
    }

    /// "Close Tab: name", or "Close Tab 2" for a tab herdr only numbers.
    static func heading(noun: String, name: String?) -> String {
        let Noun = noun.prefix(1).uppercased() + noun.dropFirst()
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "Close \(Noun)" }
        if TabTitle.isAutoNamed(name) { return "Close \(Noun) \(name)" }
        let shown = name.count > nameLimit ? String(name.prefix(nameLimit - 1)) + "…" : name
        return "Close \(Noun): \(shown)"
    }

    /// Markdown: the count it turns on is bold.
    private func summary(closing subject: CloseSubject, noun: String, busy: BusyPanes, agents: AgentSessions) -> String {
        if !agents.isEmpty {
            let count = agents.agents.count
            let stops = "Stops **\(count) running \(count == 1 ? "agent" : "agents")**"
            return agents.panes > 1 ? "\(stops) in \(agents.panes) panes" : stops
        }
        if !busy.isEmpty {
            let count = busy.count
            let state = busy.blocked == 0 ? "working" : busy.working == 0 ? "waiting for you" : "busy"
            return "There \(count == 1 ? "is" : "are") currently **\(count) \(count == 1 ? "pane" : "panes")** \(state). "
                + "Closing this \(noun) will stop \(count == 1 ? "it" : "them")."
        }
        return "This is the last \(subject.noun) in the \(noun), so the \(noun) closes with it."
    }

    private var casualtyNoun: String? {
        switch self {
        case .subjectOnly: return nil
        case .closesTab: return "tab"
        case .closesWorkspace: return "workspace"
        }
    }

    /// What the prompt calls `subject` itself: a tab by the title its strip
    /// shows, a pane by its own.
    public static func name(of subject: CloseSubject, in model: SessionModel) -> String? {
        switch subject {
        case .pane(let pane):
            return model.panes[pane]?.displayTitle
        case .tab(let tab):
            return model.tabs.values.flatMap { $0 }.first { $0.tabID == tab }.map { TabTitle.resolve($0, in: model).text }
        }
    }

    private var casualty: (description: String, buttonTitle: String)? {
        switch self {
        case .subjectOnly: return nil
        case .closesTab(let description): return (description, "Close Tab")
        case .closesWorkspace(let description): return (description, "Close Workspace")
        }
    }

    private static func isLastTab(of workspaceID: WorkspaceID, in model: SessionModel) -> Bool {
        (model.tabs[workspaceID]?.count ?? 0) <= 1
    }

    private static func workspace(holding tab: TabID, in model: SessionModel) -> WorkspaceID? {
        model.tabs.first { $0.value.contains { $0.tabID == tab } }?.key
    }

    private static func describe(tab tabID: TabID, in model: SessionModel) -> String {
        name(of: .tab(tabID), in: model) ?? "this tab"
    }

    /// herdr labels a workspace with its custom name, else its cwd's own
    /// basename, else the bare word "workspace" (`Workspace::display_name_from`
    /// in `src/workspace/git/discovery.rs`), so a label is never a position.
    private static func describe(workspace workspaceID: WorkspaceID, in model: SessionModel) -> String {
        guard let record = model.workspaces.first(where: { $0.workspaceID == workspaceID }) else {
            return "this workspace"
        }
        let label = record.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "\(record.number)" : label
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
    /// The prompt offers "Don't warn me next time", which turns off this
    /// reason alone.
    public let warnsOfAgents: Bool
    /// `title` in two parts, for a prompt that sets the name apart.
    public let action: String
    public let name: String?

    public var id: CloseSubject { subject }

    public init(
        subject: CloseSubject, title: String, action: String? = nil, name: String? = nil,
        message: String, confirmButtonTitle: String, warnsOfAgents: Bool = false
    ) {
        self.subject = subject
        self.title = title
        self.action = action ?? title
        self.name = name
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
        self.warnsOfAgents = warnsOfAgents
    }
}
