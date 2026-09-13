import Foundation

/// A zoom transition for `pane.zoom`. Raw values are the exact wire strings
/// (`PaneZoomMode` in herdr's schema is `#[serde(rename_all = "snake_case")]`
/// over `Toggle | On | Off`).
public enum ZoomMode: String, Equatable, Sendable, Codable {
    case toggle, on, off
}

/// Every mutation paddock issues against herdr, one case per gesture in the
/// design spec's verb table. `perform(_:)` on `HerdrClient` is the only
/// place that turns a case into a wire call; nothing else may call herdr
/// mutation verbs directly once Task 21 routes call sites through here.
///
/// `target: PaneID?` on `movePaneToTab` is the one legitimate nil: herdr
/// resolves a nil target to the destination tab's own focused pane (used for
/// drops onto a tab thumbnail). Every other id is always sent explicit;
/// paddock never relies on herdr's focused-pane fallback elsewhere.
public enum PrimitiveOp: Equatable, Sendable {
    case movePaneToTab(PaneID, tab: TabID, target: PaneID?, split: SplitDirection, ratio: Double?)
    case movePaneToNewTab(PaneID, workspace: WorkspaceID, label: String?)
    case movePaneToNewWorkspace(PaneID, label: String?, tabLabel: String?)
    case swapPanes(PaneID, PaneID)
    case setSplitRatio(tab: TabID, path: [Bool], ratio: Double)
    case moveTab(TabID, insertIndex: Int)
    case moveWorkspace(WorkspaceID, insertIndex: Int)
    case renamePane(PaneID, String?)
    case renameTab(TabID, String)
    case renameWorkspace(WorkspaceID, String)
    case closePane(PaneID)
    case closeTab(TabID)
    case closeWorkspace(WorkspaceID, closeGroup: Bool)
    case zoom(PaneID, mode: ZoomMode)
    case focusPane(PaneID)
    case focusTab(TabID)
    case focusWorkspace(WorkspaceID)
}

/// What later ops need out of a mutation's response. `movedPaneNewID` is
/// `pane.move`'s `move_result.pane.pane_id`: always present on a changed
/// move, and not necessarily equal to the pane id that was passed in (a
/// cross-workspace move assigns a new one). `createdTabID`/`createdWorkspaceID`
/// are populated only when the destination created one (`movePaneToNewTab`,
/// `movePaneToNewWorkspace`); every other case returns all three nil.
public struct OpResult: Sendable {
    public let movedPaneNewID: PaneID?
    public let createdTabID: TabID?
    public let createdWorkspaceID: WorkspaceID?

    public init(movedPaneNewID: PaneID? = nil, createdTabID: TabID? = nil, createdWorkspaceID: WorkspaceID? = nil) {
        self.movedPaneNewID = movedPaneNewID
        self.createdTabID = createdTabID
        self.createdWorkspaceID = createdWorkspaceID
    }
}

/// Wire rejections the planner/executor branches on. `sameTab`/`crossTab`/
/// `zoomedTab` mirror the design spec's hard constraints; source shows
/// `pane.move` and `pane.swap` deliver these as a `reason` field on an
/// otherwise-successful response rather than an `ErrorResponse`, so
/// `perform` throws this from both that success-with-reason shape and a
/// genuine error envelope, so callers only ever branch on one thing.
/// `workspaceGroupCloseRequired` is the one of the four that is a real
/// `ErrorResponse` code (`workspace.close` on a group primary). `.other`
/// carries anything else verbatim.
public enum HerdrOpError: Error, Equatable, Sendable {
    case sameTab
    case crossTab
    case zoomedTab
    case workspaceGroupCloseRequired
    case other(code: String, message: String)
}
