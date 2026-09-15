/// The workspace rail's Cmd+click selection. It is paddock's own and never
/// herdr's: herdr's selected workspace is still whatever a plain click jumps
/// to, and the two can disagree.
public struct WorkspaceSelection: Equatable, Sendable {
    public enum ClickEffect: Equatable, Sendable {
        /// A Cmd+click: the selection changed and nothing else happens.
        case toggled
        /// A plain click: the selection is gone and the row is jumped to.
        case jump(WorkspaceID)
    }

    public private(set) var ids: Set<WorkspaceID> = []

    public init(ids: Set<WorkspaceID> = []) {
        self.ids = ids
    }

    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: WorkspaceID) -> Bool { ids.contains(id) }

    public mutating func click(_ id: WorkspaceID, commandHeld: Bool) -> ClickEffect {
        guard commandHeld else {
            ids.removeAll()
            return .jump(id)
        }
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        return .toggled
    }

    public mutating func clear() {
        ids.removeAll()
    }

    /// Forgets every id `order` no longer carries, so a closed workspace
    /// cannot ride along in a later block drag.
    public mutating func retain(_ order: [WorkspaceID]) {
        let live = Set(order)
        ids.formIntersection(live)
    }

    /// What a drag starting on `id` carries: the whole selection, in rail
    /// order, when `id` belongs to a selection of two or more; otherwise
    /// `id` alone, which is the single reorder a rail drag always was.
    public func dragSubject(pressing id: WorkspaceID, order: [WorkspaceID]) -> DragSubject {
        guard ids.count > 1, ids.contains(id) else { return .workspace(id) }
        return .workspaces(order.filter(ids.contains))
    }

    /// Esc clears a selection only while no drag is live: a live drag owns
    /// Esc as its cancel, and clears the selection on that path itself.
    public func escapeClears(dragIdle: Bool) -> Bool {
        dragIdle && !ids.isEmpty
    }
}
