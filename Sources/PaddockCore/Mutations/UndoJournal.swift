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

/// Undo/redo over `ExecutedPlan`, per pane-rearrange gesture.
///
/// `undoStack` holds entries ready to undo (execute `.inverse`);
/// `redoStack` holds entries ready to redo (execute `.plan`, remapped
/// through `.paneIDRemap` first -- see below). Undo pops an undo-stack
/// entry, executes its `.inverse`, and on success pushes the SAME entry
/// (never the result of running the inverse) onto the redo stack, with its
/// `paneIDRemap` composed against whatever the inverse's own execution just
/// revealed. Redo pops a redo-stack entry, substitutes its `.plan`'s
/// literal pane ids through its `paneIDRemap` (a plan recorded against a
/// pane's ORIGINAL id must reference whatever id that same physical pane
/// currently holds, since undo's own move may have re-keyed it), executes
/// the result, and pushes THAT fresh `ExecutedPlan` -- inverse and remap
/// both newly computed against the live model -- onto the undo stack. This
/// asymmetry (undo requeues the same entry; redo produces a fresh one) is
/// what keeps `undoLabel`/`redoLabel` reading the label of the action each
/// button would actually perform, and keeps every subsequent undo running
/// against an inverse that is valid RIGHT NOW rather than one computed once
/// and replayed stale.
///
/// A popped entry is checked against the CURRENT model before it runs:
/// every literal `PaneID`/`TabID`/`WorkspaceID` the plan-to-run references
/// must still exist (a placeholder id is exempt -- it only resolves once
/// its own step has run). A `nil` model (not yet connected) restores the
/// entry rather than discarding it -- that is a transient gap, not evidence
/// the entry is actually stale. An entry whose `.inverse` has no ops at all
/// (a close: herdr has no "recreate" verb) is dropped on undo without ever
/// reaching the executor.
@MainActor
@Observable
public final class UndoJournal {
    public static let depth = 50

    private var undoStack: [ExecutedPlan] = []
    private var redoStack: [ExecutedPlan] = []
    private let executor: any PlanExecuting
    private let model: @MainActor () -> SessionModel?
    private let notify: @MainActor (String) -> Void

    /// Every `perform`/`closePane`/`undo`/`redo` call runs through this one
    /// chain (see `runExclusively`), so two of them -- issued back to back,
    /// from anywhere -- can never interleave their stack/model mutations.
    private var chain: Task<Void, Never>?
    public private(set) var isBusy = false

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

    /// Runs `body` after any step already chained through this journal
    /// finishes -- the same seam `undo`/`redo` use, exposed so
    /// `SessionViewModel.perform`/`closePane` can serialize against undo/redo
    /// too (all four mutate the same two stacks and the same live model).
    /// `isBusy` covers the whole chain, not just undo/redo, so a consumer
    /// (the Edit menu) can disable itself for the width of ANY in-flight step.
    ///
    /// Nothing bounds a step. A step waits on the executor, which waits on a
    /// herdr request that carries no deadline of its own, so a server that
    /// accepts the connection and then answers nothing parks this chain and
    /// every mutation queued behind it, with `isBusy` true, until the socket
    /// closes.
    public func runExclusively(_ body: @escaping () async -> Void) async {
        let previous = chain
        let task = Task { [weak self] in
            _ = await previous?.value
            self?.isBusy = true
            await body()
            self?.isBusy = false
        }
        chain = task
        await task.value
    }

    public func undo() async {
        await runExclusively { [weak self] in await self?.performUndo() }
    }

    public func redo() async {
        await runExclusively { [weak self] in await self?.performRedo() }
    }

    private func performUndo() async {
        guard let entry = undoStack.popLast() else { return }
        guard !entry.inverse.ops.isEmpty else {
            notify(Self.nothingToUndoNotice(for: entry))
            return
        }
        guard let liveModel = model() else {
            undoStack.append(entry)
            notify("Can't undo: \(entry.plan.label), not connected")
            return
        }
        guard Self.referencesExist(entry.inverse, model: liveModel) else {
            notify("Can't undo: \(entry.plan.label), panes changed")
            return
        }

        let result = await executor.execute(Self.addingNeedsUnzoom(to: entry.inverse, model: liveModel))
        switch result {
        case .success(let executedInverse):
            let composedRemap = Self.composeRemap(entry.paneIDRemap, then: executedInverse.paneIDRemap)
            push(
                ExecutedPlan(
                    plan: entry.plan, inverse: entry.inverse, irreversible: entry.irreversible,
                    paneIDRemap: composedRemap, positionLost: entry.positionLost
                ),
                onto: &redoStack
            )
            if entry.positionLost {
                notify("Undone into a new tab (original position not restorable)")
            }
            if !entry.irreversible.isEmpty {
                notify("Undo \(entry.plan.label) partially: \(Self.describe(entry.irreversible)) not undone")
            }
        case .failure(let failure):
            if failure.executed.isEmpty {
                // Nothing reached herdr -- the store already reverted its
                // optimistic overlay and resnapshotted, so the model is
                // exactly as it was before this attempt. Restore the entry
                // (the same transient treatment a nil model gets) so the
                // user can simply try again.
                undoStack.append(entry)
            }
            notify(Self.failureNotice(verb: "undo", label: entry.plan.label, failure: failure))
        }
    }

    private func performRedo() async {
        guard let entry = redoStack.popLast() else { return }
        guard let liveModel = model() else {
            redoStack.append(entry)
            notify("Can't redo: \(entry.plan.label), not connected")
            return
        }
        let planToRun = Self.remapPaneIDs(in: entry.plan, using: entry.paneIDRemap)
        guard Self.referencesExist(planToRun, model: liveModel) else {
            notify("Can't redo: \(entry.plan.label), panes changed")
            return
        }

        let result = await executor.execute(Self.addingNeedsUnzoom(to: planToRun, model: liveModel))
        switch result {
        case .success(let executed):
            push(executed, onto: &undoStack)
            if !entry.irreversible.isEmpty {
                notify("Redo \(entry.plan.label) partially: \(Self.describe(entry.irreversible)) not undone")
            }
        case .failure(let failure):
            if failure.executed.isEmpty {
                redoStack.append(entry)
            }
            notify(Self.failureNotice(verb: "redo", label: entry.plan.label, failure: failure))
        }
    }

    /// Only an entry whose irreversible ops are ALL closes earns the
    /// "closes are final" wording -- an empty inverse can also come from a
    /// plan of pure focus/zoom ops (`MutationEngine.simpleInverse` has no
    /// inverse for those either, and they are never marked irreversible),
    /// which is not a close at all and should not be told it is one.
    private static func nothingToUndoNotice(for entry: ExecutedPlan) -> String {
        guard !entry.irreversible.isEmpty, entry.irreversible.allSatisfy(isClose) else {
            return "Nothing to undo for \(entry.plan.label)"
        }
        return "Nothing to undo for \(entry.plan.label): closes are final"
    }

    private func push(_ executed: ExecutedPlan, onto stack: inout [ExecutedPlan]) {
        stack.append(executed)
        if stack.count > Self.depth {
            stack.removeFirst(stack.count - Self.depth)
        }
    }

    private static func failureNotice(verb: String, label: String, failure: OpFailure) -> String {
        guard !failure.executed.isEmpty else {
            return "Can't \(verb) \(label): \(failure.message)"
        }
        // Some ops in `planToRun` reached herdr before the failure -- silently
        // discarding `failure.partialInverse` here would hide that the model
        // no longer matches either the pre- or post-step state.
        return "Can't \(verb) \(label): \(failure.message) (\(failure.executed.count) step(s) already ran and were not reverted)"
    }

    /// Substitutes every LITERAL (non-placeholder) `PaneID` in `plan`'s ops
    /// through `remap`, leaving an id unmapped when `remap` has no entry for
    /// it -- a literal id this plan never itself moved is assumed unchanged;
    /// `referencesExist` (checked right after) is what catches it if that
    /// assumption turns out wrong (closed out from under it some other way).
    /// `TabID`/`WorkspaceID` literals are never re-keyed by any op, so only
    /// `PaneID` substitution is needed.
    private static func remapPaneIDs(in plan: OpPlan, using remap: [PaneID: PaneID]) -> OpPlan {
        func pane(_ id: PaneID) -> PaneID {
            guard id.planPlaceholderStep == nil else { return id }
            return remap[id] ?? id
        }
        let remappedOps = plan.ops.map { op -> PrimitiveOp in
            switch op {
            case let .movePaneToTab(p, t, target, split, ratio):
                return .movePaneToTab(pane(p), tab: t, target: target.map(pane), split: split, ratio: ratio)
            case let .movePaneToNewTab(p, workspace, label):
                return .movePaneToNewTab(pane(p), workspace: workspace, label: label)
            case let .movePaneToNewWorkspace(p, label, tabLabel):
                return .movePaneToNewWorkspace(pane(p), label: label, tabLabel: tabLabel)
            case let .swapPanes(a, b):
                return .swapPanes(pane(a), pane(b))
            case let .renamePane(p, label):
                return .renamePane(pane(p), label)
            case let .closePane(p):
                return .closePane(pane(p))
            case let .zoom(p, mode):
                return .zoom(pane(p), mode: mode)
            case let .focusPane(p):
                return .focusPane(pane(p))
            case .setSplitRatio, .moveTab, .moveWorkspace, .moveWorkspaceBlock, .renameTab, .renameWorkspace,
                 .closeTab, .closeWorkspace, .focusTab, .focusWorkspace:
                return op
            }
        }
        return OpPlan(ops: remappedOps, label: plan.label, needsUnzoom: plan.needsUnzoom)
    }

    /// Chains two remaps end to end: for every `(origin, mid)` in `first`,
    /// look `mid` up in `second` (falling back to `mid` itself when `second`
    /// never touched that pane) -- so a pane re-keyed once by the plan an
    /// entry was first recorded from, and again by whatever its inverse just
    /// ran, still resolves from its ORIGINAL id all the way to its truly
    /// current one.
    private static func composeRemap(_ first: [PaneID: PaneID], then second: [PaneID: PaneID]) -> [PaneID: PaneID] {
        var composed = first
        for (origin, mid) in first {
            composed[origin] = second[mid] ?? mid
        }
        return composed
    }

    /// Neither `entry.inverse` nor a redo's remapped `entry.plan` ever
    /// carries a `needsUnzoom` of its own -- the forward gesture planner's
    /// `OpPlan.needsUnzoom` only ever covered THAT gesture's own tabs, and
    /// this journal builds no equivalent when it hands either plan back to
    /// the executor. Computed fresh here, from the CURRENT model, over every
    /// tab the plan's own ops reference, so a tab zoomed now (regardless of
    /// whether it was zoomed when the entry was first recorded) is still
    /// unzoomed before these ops run.
    private static func addingNeedsUnzoom(to plan: OpPlan, model: SessionModel) -> OpPlan {
        var tabs: [TabID] = []
        for op in plan.ops {
            for tab in tabsReferenced(by: op, model: model) where model.layouts[tab]?.zoomed == true && !tabs.contains(tab) {
                tabs.append(tab)
            }
        }
        // Always rebuilt, even to empty: `plan.needsUnzoom` can carry a
        // stale list from whatever recorded it (the original forward plan,
        // copied verbatim through `remapPaneIDs` for a redo) -- returning
        // `plan` unchanged when nothing is zoomed NOW would replay that
        // stale list and unzoom a tab that is not zoomed, which herdr's own
        // zoom handler still focuses as a side effect (a spurious hijack).
        return OpPlan(ops: plan.ops, label: plan.label, needsUnzoom: tabs)
    }

    private static func tabsReferenced(by op: PrimitiveOp, model: SessionModel) -> [TabID] {
        func tabOfPane(_ id: PaneID) -> TabID? {
            guard id.planPlaceholderStep == nil else { return nil }
            return model.panes[id]?.tabID
        }
        switch op {
        case let .movePaneToTab(p, t, target, _, _):
            return [tabOfPane(p), t, target.flatMap(tabOfPane)].compactMap { $0 }
        case let .movePaneToNewTab(p, _, _):
            return [tabOfPane(p)].compactMap { $0 }
        case let .movePaneToNewWorkspace(p, _, _):
            return [tabOfPane(p)].compactMap { $0 }
        case let .swapPanes(a, b):
            return [tabOfPane(a), tabOfPane(b)].compactMap { $0 }
        case let .setSplitRatio(t, _, _):
            return [t]
        case let .moveTab(t, _):
            return [t]
        case let .renameTab(t, _):
            return [t]
        case let .closeTab(t):
            return [t]
        case let .zoom(p, _):
            return [tabOfPane(p)].compactMap { $0 }
        case let .focusPane(p):
            return [tabOfPane(p)].compactMap { $0 }
        case let .focusTab(t):
            return [t]
        case .moveWorkspace, .moveWorkspaceBlock, .renamePane, .renameWorkspace, .closePane, .closeWorkspace, .focusWorkspace:
            return []
        }
    }

    private static func referencesExist(_ plan: OpPlan, model: SessionModel) -> Bool {
        plan.ops.allSatisfy { referencesExist($0, model: model) }
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
        case let .moveWorkspaceBlock(block, before):
            return block.allSatisfy(workspace) && (before.map(workspace) ?? true)
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

    /// Describes what `irreversible` left standing, for the partial-undo/
    /// redo notice. A close is the only op family that ever lands here (see
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
