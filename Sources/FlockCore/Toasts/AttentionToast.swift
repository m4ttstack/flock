import Foundation

/// One pane asking to be looked at.
///
/// Identified by its pane, not by a fresh id per raise: a pane has at most
/// one live toast, which is the rule Herdglass reaches by the same reasoning
/// on the OS notification centre ("one notification per pane... a pane that
/// goes blocked and later done replaces its own banner"). Making the pane the
/// identity puts that rule in the type rather than in the code that keeps it.
public struct AttentionToast: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The agent stopped and is waiting on the user. Stays until it is
        /// handled or dismissed.
        case needsInput
        /// The agent finished what it was working on. Auto-dismisses.
        case finished
    }

    public var id: PaneID { paneID }
    public let paneID: PaneID
    public let tabID: TabID
    public let workspaceID: WorkspaceID
    public var kind: Kind
    /// "migration needs input" -- the pane, and what it wants.
    public var headline: String
    /// "flock › migration" -- where to look for it.
    public var breadcrumb: String
    public var raisedAt: Date

    public var accessibilityIdentifier: String { "flock.attention.toast.\(paneID.rawValue)" }

    public init(
        paneID: PaneID, tabID: TabID, workspaceID: WorkspaceID, kind: Kind,
        headline: String, breadcrumb: String, raisedAt: Date
    ) {
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.kind = kind
        self.headline = headline
        self.breadcrumb = breadcrumb
        self.raisedAt = raisedAt
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
        let want = switch kind {
        case .needsInput: "needs input"
        case .finished: "finished"
        }
        return AttentionToast(
            paneID: pane.paneID,
            tabID: pane.tabID,
            workspaceID: pane.workspaceID,
            kind: kind,
            headline: "\(pane.displayTitle) \(want)",
            breadcrumb: "\(workspaceLabel) › \(tabLabel)",
            raisedAt: raisedAt
        )
    }
}
