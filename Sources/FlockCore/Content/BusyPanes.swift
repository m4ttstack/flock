import Foundation

/// The panes a close would interrupt: the ones herdr reports as `working` or
/// `blocked` inside whatever the close is about to destroy.
///
/// Closing a pane among siblings escalates nothing, so it used to go straight
/// out with nothing on screen. That is the case worth asking about: the
/// container is cheap and the work in it is not.
///
/// **`unknown` deliberately does not count.** herdr reports a plain shell as
/// `unknown`, so counting it would prompt on nearly every close, including a
/// pane holding an idle prompt. The cost of that choice, stated plainly: a
/// shell running a long build closes silently, because nothing in the session
/// model distinguishes it from a shell sitting at a prompt. Only a pane with
/// an agent herdr can see is protected here.
public struct BusyPanes: Equatable, Sendable {
    /// What "busy" means. `blocked` is in it because a pane waiting on the
    /// user is holding a decision, and throwing that away is the same loss as
    /// throwing away work in flight.
    public static let busyStatuses: Set<AgentStatus> = [.working, .blocked]

    public let working: Int
    public let blocked: Int

    public static let none = BusyPanes(working: 0, blocked: 0)

    public var count: Int { working + blocked }
    public var isEmpty: Bool { count == 0 }

    public init(working: Int, blocked: Int) {
        self.working = working
        self.blocked = blocked
    }

    /// Every pane the close destroys, weighed. A pane close takes that pane; a
    /// tab close takes its panes; an escalating close takes the workspace's,
    /// which is why the blast radius is derived from the consequence rather
    /// than from the subject alone.
    public init(closing subject: CloseSubject, consequence: CloseConsequence, model: SessionModel) {
        let panes = Self.destroyed(by: subject, consequence: consequence, model: model)
        self.init(
            working: panes.count { $0.agentStatus == .working },
            blocked: panes.count { $0.agentStatus == .blocked }
        )
    }

    /// Every busy pane in ONE workspace, for the group close's own prompt.
    ///
    /// A group close takes the primary workspace and its linked worktree
    /// workspaces, but flock cannot count those: `WorkspaceRecord` carries no
    /// group or link field, and the group is discovered reactively, from
    /// herdr refusing a plain close with `workspace_group_close_required`. So
    /// this is a floor, not a total, and `groupSentence` words it as such
    /// rather than implying it counted the rest.
    public init(inWorkspace workspace: WorkspaceID, model: SessionModel) {
        let panes = model.panes.values.filter { $0.workspaceID == workspace }
        self.init(
            working: panes.count { $0.agentStatus == .working },
            blocked: panes.count { $0.agentStatus == .blocked }
        )
    }

    private static func destroyed(
        by subject: CloseSubject, consequence: CloseConsequence, model: SessionModel
    ) -> [PaneRecord] {
        switch (subject, consequence) {
        case (.pane(let pane), .subjectOnly):
            return model.panes[pane].map { [$0] } ?? []
        case (.pane(let pane), _):
            // An escalating pane close takes its tab, and possibly the
            // workspace, but a tab whose last pane is leaving has no OTHER
            // panes by definition, so the radius is still just this one.
            return model.panes[pane].map { [$0] } ?? []
        case (.tab(let tab), .closesWorkspace):
            guard let workspace = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key
            else { return [] }
            return model.panes.values.filter { $0.workspaceID == workspace }
        case (.tab(let tab), _):
            return model.panes.values.filter { $0.tabID == tab }
        }
    }

    /// How the prompt says it aloud, or nil when nothing is busy. Counts
    /// rather than names: a pane's title is its program's terminal title,
    /// which changes under the prompt while it is open.
    var sentence: String? {
        guard !isEmpty else { return nil }
        switch (working, blocked) {
        case (let w, 0):
            return "\(w) \(Self.paneWord(w)) still working."
        case (0, let b):
            return "\(b) \(Self.paneWord(b)) waiting for you."
        case (let w, let b):
            return "\(w) \(Self.paneWord(w)) still working and \(b) waiting for you."
        }
    }

    /// The group close's wording. Scoped to "in this workspace" on purpose:
    /// the count covers the primary only, and the prompt it joins already
    /// says the linked workspaces are going too, so an unscoped number there
    /// would read as a total it never counted.
    public var groupSentence: String? {
        guard !isEmpty else { return nil }
        switch (working, blocked) {
        case (let w, 0):
            return "\(w) \(Self.paneWord(w)) still working in this workspace."
        case (0, let b):
            return "\(b) \(Self.paneWord(b)) waiting for you in this workspace."
        case (let w, let b):
            return "In this workspace, \(w) \(Self.paneWord(w)) still working and \(b) waiting for you."
        }
    }

    private static func paneWord(_ count: Int) -> String {
        count == 1 ? "pane is" : "panes are"
    }
}
