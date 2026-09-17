/// herdr's attention order over agent states, and the group status it
/// derives from it.
///
/// herdr keeps one rule for both (`Workspace::aggregate_state` over
/// `pane_attention_priority`, and the shell's `status_priority`): the loudest
/// pane in a group is the group's status. flock re-derives it only because
/// a live `pane.agent_status_changed` frame names one pane and herdr sends
/// the group's own value in snapshots alone.
public enum AgentAttention {
    public static func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    /// `.unknown` for an empty group, which is what herdr reports for a
    /// workspace it can read no pane state from.
    public static func aggregate(_ statuses: some Sequence<AgentStatus>) -> AgentStatus {
        statuses.max { rank($0) < rank($1) } ?? .unknown
    }
}
