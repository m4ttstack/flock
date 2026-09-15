import Foundation

/// Where a drag gesture's subject was released, per the design spec's verb
/// table's drop-target taxonomy.
public enum DropTarget: Equatable, Sendable {
    case paneEdge(PaneID, Edge)
    case paneInterior(PaneID)
    case tabStrip(workspace: WorkspaceID, insertIndex: Int)
    case tabThumbnail(TabID)
    case workspaceThumbnail(WorkspaceID)
    case newTab(WorkspaceID)
    case newWorkspace
    case workspaceRail(insertIndex: Int)
}

/// What a drag gesture is carrying.
public enum DragSubject: Equatable, Sendable {
    case pane(PaneID)
    case tab(TabID)
    case workspace(WorkspaceID)
    /// A rail multi-selection moving as one block, in rail order.
    case workspaces([WorkspaceID])
}

/// An ordered list of mutations that realizes one gesture, produced by
/// `plan(dragging:onto:model:)`.
///
/// `needsUnzoom` names every tab the executor must auto-unzoom (with a
/// toast) before running `ops`, per the design spec's auto-unzoom-on-move
/// rule; the planner never appends a compensating re-zoom afterward.
///
/// Focus is the executor's concern, not the plan's: `pane.move` never
/// focuses the moved pane on the wire (confirmed against herdr directly),
/// and this planner does not add a `focusPane`/`focusTab` op to compensate
/// either. Restoring focus after a plan runs is the executor's job.
///
/// Some ops need an id this plan cannot know until an earlier op in the same
/// plan has actually executed against herdr: the tab `movePaneToNewTab`
/// creates, or the new id a cross-workspace move assigns the pane it moved
/// (`pane.moved` is authoritative for that re-key, confirmed live). Rather
/// than introduce a second op representation, those ids are carried as
/// reserved sentinel `TabID`/`PaneID` values -- see
/// `TabID.planPlaceholder(createdByStep:)` and
/// `PaneID.planPlaceholder(movedByStep:)` -- so `ops` stays exactly
/// `[PrimitiveOp]`, comparable directly in tests. Before executing `ops[i]`,
/// the executor must resolve every placeholder id `ops[i]` contains against
/// the `OpResult` already returned by the step index the placeholder names,
/// substituting the real id; a placeholder must never reach herdr's wire.
public struct OpPlan: Equatable, Sendable {
    public let ops: [PrimitiveOp]
    public let label: String
    public let needsUnzoom: [TabID]

    public init(ops: [PrimitiveOp], label: String, needsUnzoom: [TabID] = []) {
        self.ops = ops
        self.label = label
        self.needsUnzoom = needsUnzoom
    }
}

/// Why `plan(dragging:onto:model:)` could not produce a plan.
public enum PlanError: Error, Equatable, Sendable {
    /// The gesture has no effect (e.g. a pane dropped on itself).
    case noOp
    /// This subject/target pairing is not a defined gesture (e.g. a tab
    /// dropped on a pane edge), or names an id absent from `model`.
    case invalidCombination
}

/// Shared parsing for the two placeholder id kinds below: a reserved prefix
/// (leading NUL, which no wire-assigned herdr id can contain) plus the step
/// index, so a placeholder can never collide with a real id and is always
/// recoverable back to the step that will produce its real value.
private enum PlanPlaceholder {
    static let createdTabPrefix = "\u{0}paddock.plan.createdTab."
    static let movedPanePrefix = "\u{0}paddock.plan.movedPane."

    static func step(fromRawValue rawValue: String, prefix: String) -> Int? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        return Int(rawValue.dropFirst(prefix.count))
    }
}

extension TabID {
    /// Stands in for the real `OpResult.createdTabID` `ops[step]` will
    /// return once executed (`movePaneToNewTab`/`movePaneToNewWorkspace` are
    /// the only ops that create one).
    public static func planPlaceholder(createdByStep step: Int) -> TabID {
        TabID(rawValue: PlanPlaceholder.createdTabPrefix + String(step))
    }

    /// The step index this id stands in for, or `nil` if this is a real id.
    public var planPlaceholderStep: Int? {
        PlanPlaceholder.step(fromRawValue: rawValue, prefix: PlanPlaceholder.createdTabPrefix)
    }
}

extension PaneID {
    /// Stands in for the real `OpResult.movedPaneNewID` `ops[step]` will
    /// return once executed -- needed only when that step's move crossed a
    /// workspace; a same-workspace move round-trips the same pane id.
    public static func planPlaceholder(movedByStep step: Int) -> PaneID {
        PaneID(rawValue: PlanPlaceholder.movedPanePrefix + String(step))
    }

    /// The step index this id stands in for, or `nil` if this is a real id.
    public var planPlaceholderStep: Int? {
        PlanPlaceholder.step(fromRawValue: rawValue, prefix: PlanPlaceholder.movedPanePrefix)
    }
}
