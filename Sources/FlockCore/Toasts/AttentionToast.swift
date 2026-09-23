import Foundation

/// One pane asking to be looked at.
///
/// Identified by its pane, not by a fresh id per raise: a pane has at most
/// one live toast, which is the rule Herdglass reaches by the same reasoning
/// on the OS notification centre ("one notification per pane... a pane that
/// goes blocked and later done replaces its own banner"). Making the pane the
/// identity puts that rule in the type rather than in the code that keeps it.
public struct AttentionToast: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The agent stopped and is waiting on the user. Stays until it is
        /// handled or dismissed.
        case needsInput
        /// The agent finished what it was working on. Auto-dismisses.
        case finished

        /// What the pane wants, as a card leads with it: the part a narrow
        /// card keeps whole while the pane's own title gives way.
        public var label: String {
            switch self {
            case .needsInput: "Needs input"
            case .finished: "Finished"
            }
        }
    }

    public var id: PaneID { paneID }
    public let paneID: PaneID
    public let tabID: TabID
    public let workspaceID: WorkspaceID
    public var kind: Kind
    /// "migration" -- the pane's own title.
    public var subject: String
    /// "flock › migration" -- where to look for it.
    public var breadcrumb: String
    public var raisedAt: Date
    /// herdr's status for the pane when this was raised. The toast lasts
    /// exactly as long as that status does: herdr moves a finished agent from
    /// `done` to `idle` once someone looks at the pane, and off `blocked` once
    /// the question is answered.
    public var announcedStatus: AgentStatus

    /// "migration needs input" -- the pane, and what it wants.
    public var headline: String {
        switch kind {
        case .needsInput: "\(subject) needs input"
        case .finished: "\(subject) finished"
        }
    }

    public var accessibilityIdentifier: String { "flock.attention.toast.\(paneID.rawValue)" }

    public init(
        paneID: PaneID, tabID: TabID, workspaceID: WorkspaceID, kind: Kind,
        subject: String, breadcrumb: String, raisedAt: Date, announcedStatus: AgentStatus? = nil
    ) {
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.kind = kind
        self.subject = subject
        self.breadcrumb = breadcrumb
        self.raisedAt = raisedAt
        self.announcedStatus = announcedStatus ?? (kind == .needsInput ? .blocked : .done)
    }

    /// The status a toast of this kind is reporting, which is what colors its
    /// dot: the same status roles every other mark in the window reads from.
    public var status: AgentStatus {
        switch kind {
        case .needsInput: .blocked
        case .finished: .done
        }
    }

    public static func make(kind: Kind, pane: PaneRecord, model: SessionModel, raisedAt: Date) -> AttentionToast {
        let workspaceLabel = model.workspaces.first { $0.workspaceID == pane.workspaceID }?.label
            ?? pane.workspaceID.rawValue
        let tabLabel = model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }?.label
            ?? pane.tabID.rawValue
        return AttentionToast(
            paneID: pane.paneID,
            tabID: pane.tabID,
            workspaceID: pane.workspaceID,
            kind: kind,
            subject: pane.displayTitle,
            breadcrumb: "\(workspaceLabel) › \(tabLabel)",
            raisedAt: raisedAt,
            announcedStatus: pane.agentStatus
        )
    }
}
