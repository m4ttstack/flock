import CoreGraphics

/// The workspace rail's Cmd+click selection. It is paddock's own and never
/// herdr's: herdr's selected workspace is still whatever a plain click jumps
/// to, and the two can disagree.
///
/// Keyboard focus never leaves the terminal for the rail, so Esc is the
/// terminal's unless the rail is what the user is working with right now.
/// `isRailEngaged` holds from a press on a rail row until the next press
/// anywhere else, the next other key, or the app going inactive; only then
/// may the rail take an Esc.
public struct WorkspaceSelection: Equatable, Sendable {
    public enum ClickEffect: Equatable, Sendable {
        /// A Cmd+click: the selection changed and nothing else happens.
        case toggled
        /// A plain click: the selection is gone and the row is jumped to.
        case jump(WorkspaceID)
    }

    public private(set) var ids: Set<WorkspaceID> = []
    public private(set) var isRailEngaged = false

    public init(ids: Set<WorkspaceID> = []) {
        self.ids = ids
    }

    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: WorkspaceID) -> Bool { ids.contains(id) }

    public mutating func click(_ id: WorkspaceID, commandHeld: Bool) -> ClickEffect {
        isRailEngaged = true
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

    /// Any mouse button, anywhere in the app. A press that misses the rail's
    /// rows ends the selection, whatever it lands on.
    public mutating func pointerPressed(onRailRow: Bool) {
        isRailEngaged = onRailRow
        if !onRailRow {
            ids.removeAll()
        }
    }

    /// A key other than Esc, or the app going inactive: the user is back at
    /// the terminal. The selection stays visible, but Esc is no longer the
    /// rail's.
    public mutating func disengage() {
        isRailEngaged = false
    }

    /// Whether the rail takes this Esc, clearing the selection as it does.
    /// Never while a drag is live, which owns Esc as its cancel. When this
    /// returns false nothing has changed and the Esc must reach the focused
    /// view.
    public mutating func escapePressed(dragIdle: Bool) -> Bool {
        guard dragIdle, isRailEngaged, !ids.isEmpty else { return false }
        ids.removeAll()
        isRailEngaged = false
        return true
    }

    /// Only a drag of the rail's own rows ends the selection, by drop or by
    /// Esc; a pane or tab drag leaves it alone.
    public mutating func dragFinished(_ subject: DragSubject) {
        switch subject {
        case .workspace, .workspaces:
            ids.removeAll()
        case .pane, .tab:
            break
        }
    }

    /// Forgets every id `order` no longer carries, so a closed workspace
    /// cannot ride along in a later block drag.
    public mutating func retain(_ order: [WorkspaceID]) {
        ids.formIntersection(Set(order))
    }

    /// What a drag starting on `id` carries: the whole selection, in rail
    /// order, when `id` belongs to a selection of two or more; otherwise
    /// `id` alone.
    public func dragSubject(pressing id: WorkspaceID, order: [WorkspaceID]) -> DragSubject {
        guard ids.count > 1, ids.contains(id) else { return .workspace(id) }
        return .workspaces(order.filter(ids.contains))
    }

    /// Whether a press at `point` lands on a rail row. A row scrolled out of
    /// the rail's viewport is not there to press.
    public static func isRailRow(_ point: CGPoint, rows: [CGRect], viewport: CGRect?) -> Bool {
        guard viewport?.contains(point) ?? true else { return false }
        return rows.contains { $0.contains(point) }
    }
}
