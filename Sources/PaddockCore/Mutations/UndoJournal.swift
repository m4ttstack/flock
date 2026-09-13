import Foundation
import Observation

/// What executes an `OpPlan` for real. `HerdrStore.execute` is the only
/// production conformer -- routing undo/redo through this (rather than
/// `MutationEngine` directly) is what keeps them inside the same optimistic
/// overlay and convergence watch every other mutation gets.
@MainActor
public protocol PlanExecuting: AnyObject {
    func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure>
}

extension HerdrStore: PlanExecuting {}

/// Undo/redo over `ExecutedPlan.inverse`, per pane-rearrange gesture.
///
/// Both stacks hold `ExecutedPlan`s, not raw `OpPlan`s: undoing an entry
/// means executing its `inverse`, and the `ExecutedPlan` THAT execution
/// returns is itself pushed onto the opposite stack -- its own `.inverse` is
/// exactly the plan that re-creates the entry just undone (the same
/// placeholder-substitution machinery that made the original plan
/// resolution-order-independent runs again, fresh, on each of these
/// re-executions), so redo is simply "execute the popped entry's inverse"
/// with no separate representation for "the forward direction" ever needed.
///
/// A popped entry is checked against the CURRENT model before it runs: every
/// literal `PaneID`/`TabID`/`WorkspaceID` its `inverse` references must still
/// exist (a placeholder id is exempt -- it only resolves once its own step
/// has run, so it cannot be checked ahead of time and is never stale in this
/// sense). A stale entry is dropped without being executed.
@MainActor
@Observable
public final class UndoJournal {
    public static let depth = 50

    private var undoStack: [ExecutedPlan] = []
    private var redoStack: [ExecutedPlan] = []
    private let executor: any PlanExecuting
    private let model: @MainActor () -> SessionModel?
    private let notify: @MainActor (String) -> Void

    public init(
        executor: any PlanExecuting,
        model: @escaping @MainActor () -> SessionModel?,
        notify: @escaping @MainActor (String) -> Void
    ) {
        self.executor = executor
        self.model = model
        self.notify = notify
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.plan.label }
    public var redoLabel: String? { redoStack.last?.plan.label }

    /// Pushes a freshly executed plan onto the undo stack (evicting the
    /// oldest entry past `depth`) and clears whatever could have been
    /// redone: a new recorded action makes the old redo branch stale by
    /// definition, the same rule every undo/redo history follows.
    public func record(_ executed: ExecutedPlan) {
        undoStack.append(executed)
        if undoStack.count > Self.depth {
            undoStack.removeFirst(undoStack.count - Self.depth)
        }
        redoStack.removeAll()
    }

    public func undo() async {
        await step(direction: .undo)
    }

    public func redo() async {
        await step(direction: .redo)
    }

    private enum Direction {
        case undo, redo
        var verb: String {
            switch self {
            case .undo: return "undo"
            case .redo: return "redo"
            }
        }
    }

    /// Both directions are the same shape (per this type's own doc comment:
    /// undo and redo are each just "execute the popped entry's inverse and
    /// push what came back onto the other stack"), so one method reads/
    /// writes `undoStack`/`redoStack` directly rather than threading them as
    /// `inout` across the `await` below.
    private func step(direction: Direction) async {
        let entry: ExecutedPlan?
        switch direction {
        case .undo: entry = undoStack.popLast()
        case .redo: entry = redoStack.popLast()
        }
        guard let entry else { return }
        guard isFresh(entry) else {
            notify("Can't \(direction.verb): \(entry.plan.label), panes changed")
            return
        }
        let result = await executor.execute(entry.inverse)
        switch result {
        case .success(let executedInverse):
            switch direction {
            case .undo: push(executedInverse, onto: &redoStack)
            case .redo: push(executedInverse, onto: &undoStack)
            }
            if !entry.irreversible.isEmpty {
                notify("\(direction.verb.capitalized) \(entry.plan.label) partially: \(Self.describe(entry.irreversible)) not undone")
            }
        case .failure(let failure):
            notify("Can't \(direction.verb) \(entry.plan.label): \(failure.message)")
        }
    }

    private func push(_ executed: ExecutedPlan, onto stack: inout [ExecutedPlan]) {
        stack.append(executed)
        if stack.count > Self.depth {
            stack.removeFirst(stack.count - Self.depth)
        }
    }

    /// `entry.inverse` is about to run against the live model, so every
    /// literal id it names must still be in it -- a placeholder never is,
    /// but it also never needs to be (it resolves fresh off that inverse's
    /// own `OpResult`s once it starts running, exactly like any other plan).
    private func isFresh(_ entry: ExecutedPlan) -> Bool {
        guard let model = model() else { return false }
        return entry.inverse.ops.allSatisfy { Self.referencesExist($0, model: model) }
    }

    private static func referencesExist(_ op: PrimitiveOp, model: SessionModel) -> Bool {
        func pane(_ id: PaneID) -> Bool { id.planPlaceholderStep != nil || model.panes[id] != nil }
        func tab(_ id: TabID) -> Bool { id.planPlaceholderStep != nil || model.tabs.values.contains { $0.contains { $0.tabID == id } } }
        func workspace(_ id: WorkspaceID) -> Bool { model.workspaces.contains { $0.workspaceID == id } }

        switch op {
        case let .movePaneToTab(p, t, target, _, _):
            return pane(p) && tab(t) && (target.map(pane) ?? true)
        case let .movePaneToNewTab(p, w, _):
            return pane(p) && workspace(w)
        case let .movePaneToNewWorkspace(p, _, _):
            return pane(p)
        case let .swapPanes(a, b):
            return pane(a) && pane(b)
        case let .setSplitRatio(t, _, _):
            return tab(t)
        case let .moveTab(t, _):
            return tab(t)
        case let .moveWorkspace(w, _):
            return workspace(w)
        case let .renamePane(p, _):
            return pane(p)
        case let .renameTab(t, _):
            return tab(t)
        case let .renameWorkspace(w, _):
            return workspace(w)
        case let .closePane(p):
            return pane(p)
        case let .closeTab(t):
            return tab(t)
        case let .closeWorkspace(w, _):
            return workspace(w)
        case let .zoom(p, _):
            return pane(p)
        case let .focusPane(p):
            return pane(p)
        case let .focusTab(t):
            return tab(t)
        case let .focusWorkspace(w):
            return workspace(w)
        }
    }

    /// Describes what `irreversible` left standing, for the partial-undo
    /// notice. A close is the only op family that ever lands here (see
    /// `MutationEngine.simpleInverse`'s doc comment), so a single close is
    /// named directly rather than spelled out as "1 change".
    private static func describe(_ ops: [PrimitiveOp]) -> String {
        if ops.count == 1, Self.isClose(ops[0]) {
            return "the pane close"
        }
        return "\(ops.count) closes"
    }

    private static func isClose(_ op: PrimitiveOp) -> Bool {
        switch op {
        case .closePane, .closeTab, .closeWorkspace: return true
        default: return false
        }
    }
}
