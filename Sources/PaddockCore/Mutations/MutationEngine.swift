import Foundation

/// What `MutationEngine.execute` produced. `plan` is the original plan
/// exactly as given, placeholders and all -- never the resolved form -- so a
/// redo can re-run it through the same substitution logic and pick up
/// whatever ids herdr assigns the second time, rather than replaying stale
/// concrete ids from the first run. `inverse` is built from the ops that
/// actually ran. `irreversible` names every op in `plan` whose inverse was
/// omitted (a genuine close, not a bounce's own throwaway temp-tab cleanup),
/// so the undo journal can label this entry as partially irreversible rather
/// than silently under-restoring. `paneIDRemap` maps every literal `PaneID`
/// `plan.ops` referenced as a move's own source to whatever id that same
/// physical pane ended up with once every op in `plan` finished running --
/// the undo journal composes this across successive undo/redo cycles to
/// keep re-executing a re-planned `plan` pointed at the pane's true current
/// identity, since a cross-workspace move re-keys the pane on every hop.
/// `positionLost` is true when `inverse` itself recreates a tab rather than
/// restoring the pane to its original one (see `MoveTracker.buildInverseOps`'s
/// `positionLost` -- a lone pane's own origin tab dies the moment it leaves,
/// same as a migration's), so undoing THIS entry lands the pane somewhere
/// only approximately right; the undo journal surfaces that to the user
/// rather than letting it pass as a silent, exact restore.
public struct ExecutedPlan: Equatable, Sendable {
    public let plan: OpPlan
    public let inverse: OpPlan
    public let irreversible: [PrimitiveOp]
    public let paneIDRemap: [PaneID: PaneID]
    public let positionLost: Bool

    public init(
        plan: OpPlan, inverse: OpPlan, irreversible: [PrimitiveOp] = [],
        paneIDRemap: [PaneID: PaneID] = [:], positionLost: Bool = false
    ) {
        self.plan = plan
        self.inverse = inverse
        self.irreversible = irreversible
        self.paneIDRemap = paneIDRemap
        self.positionLost = positionLost
    }
}

/// Reported when `perform` throws partway through a plan, or when a
/// placeholder id cannot be resolved before ever reaching `perform`.
/// `executed` is every op (unzoom included) that actually reached herdr
/// before `failedOp`, in the order it ran -- the executor never rolls these
/// back itself; the store converges on the real events those ops caused and
/// the failure surfaces to the UI as-is. `partialInverse` is the inverse of
/// exactly what `executed` ran, so a caller can still undo the partial
/// effect even though the plan as a whole did not complete.
public struct OpFailure: Error, Equatable, Sendable {
    public let failedOp: PrimitiveOp
    public let code: String
    public let message: String
    public let executed: [PrimitiveOp]
    public let partialInverse: OpPlan

    public init(failedOp: PrimitiveOp, code: String, message: String, executed: [PrimitiveOp], partialInverse: OpPlan) {
        self.failedOp = failedOp
        self.code = code
        self.message = message
        self.executed = executed
        self.partialInverse = partialInverse
    }
}

/// Runs one `OpPlan` against herdr for real. Unzooms every `needsUnzoom` tab
/// first, then runs `plan.ops` in order, substituting each placeholder id
/// against the `OpResult` the step it names already returned (see `OpPlan`'s
/// own doc comment for the placeholder contract this reads). Stops at the
/// first failure and reports it rather than attempting any rollback of its
/// own -- see `OpFailure`.
public actor MutationEngine {
    private let client: HerdrClient

    public init(client: HerdrClient) {
        self.client = client
    }

    public func execute(_ plan: OpPlan, model: SessionModel) async -> Result<ExecutedPlan, OpFailure> {
        var executed: [PrimitiveOp] = []
        var irreversible: [PrimitiveOp] = []
        var tracker = MoveTracker()
        var simpleInverseOps: [PrimitiveOp] = []

        // Move-group ops always come first, simple ops after: a move
        // group's own placeholders are built relative to position 0 of
        // wherever it lands, so putting it first is what keeps those step
        // indices correct without threading an offset through the tracker.
        // This ordering is exact, not arbitrary, only because no
        // planner-produced plan ever mixes a move with a simple op (rename/
        // swap/reorder) in the first place, and a simple op's own inverse
        // does not depend on anything a move touched, so the two commute --
        // reordering one relative to the other changes nothing about
        // either's own correctness. A hand-built plan that DOES mix them is
        // still undone correctly per op, just not necessarily in true
        // reverse-chronological order across the two families.
        func partialInverse() -> OpPlan {
            OpPlan(ops: tracker.buildInverseOps().ops + simpleInverseOps, label: "Undo \(plan.label)")
        }

        var unzoomRan = false
        for tabID in plan.needsUnzoom {
            guard let pane = Self.unzoomTarget(forTab: tabID, model: model) else { continue }
            let op = PrimitiveOp.zoom(pane, mode: .off)
            do {
                _ = try await client.perform(op)
                executed.append(op)
                unzoomRan = true
            } catch {
                let (code, message) = Self.describe(error)
                return .failure(OpFailure(failedOp: op, code: code, message: message, executed: executed, partialInverse: partialInverse()))
            }
        }

        var results: [Int: OpResult] = [:]
        var trackedFocusID = model.focusedPaneID
        var focusNeedsRestore = false

        for (index, rawOp) in plan.ops.enumerated() {
            guard let op = Self.resolvePlaceholders(rawOp, results: results) else {
                // A placeholder this op carries names a step that never ran
                // or never resolved to an id -- the sentinel must never
                // reach the wire, so this is a plan failure, not a silent
                // pass-through of the raw sentinel string.
                return .failure(OpFailure(
                    failedOp: rawOp, code: "unresolved_placeholder",
                    message: "a placeholder id in this op has no resolved value yet", executed: executed, partialInverse: partialInverse()
                ))
            }

            if let source = Self.sourcePane(of: op), let tracked = trackedFocusID, source == tracked {
                focusNeedsRestore = true
            }

            do {
                let result = try await client.perform(op)
                results[index] = result
                executed.append(op)

                if let source = Self.sourcePane(of: op) {
                    if let newID = result.movedPaneNewID, source == trackedFocusID {
                        trackedFocusID = newID
                    }
                    tracker.record(rawOp: rawOp, resolvedOp: op, resolvedSource: source, result: result, stepIndex: index, model: model)
                } else if Self.isCompensatingSwap(op, tracker: tracker) {
                    // A swapPanes immediately paired with an earlier move in
                    // THIS plan (the left/top edge asymmetry, in both the
                    // bounce and the plain cross-tab shapes) exists only to
                    // arrange the FORWARD destination; the move's own origin
                    // record (side) already reconstructs the correct
                    // arrangement on undo, so a standalone "swap again" entry
                    // here would double it back to no swap at all.
                } else if let inverseOp = Self.simpleInverse(for: op, model: model) {
                    simpleInverseOps.insert(inverseOp, at: 0)
                } else if Self.isCloseOp(op), !Self.isPlaceholderTabCleanup(rawOp) {
                    irreversible.append(op)
                }
            } catch {
                if case let .closeTab(rawTabTarget) = rawOp, rawTabTarget.planPlaceholderStep != nil, Self.isTabNotFound(error) {
                    // herdr auto-closes a bounce plan's temp tab the instant
                    // its last pane leaves, so this closeTab is routinely a
                    // no-op cleanup arriving too late to find its target --
                    // that is success, not a failure to report.
                    // Scoped to a placeholder tab id: a literal-id closeTab
                    // returning tab_not_found names a real target that is
                    // genuinely missing, which is a real failure.
                    executed.append(op)
                    continue
                }
                let (code, message) = Self.describe(error)
                return .failure(OpFailure(failedOp: op, code: code, message: message, executed: executed, partialInverse: partialInverse()))
            }
        }

        // Neither correction below may run when the plan's own last op is
        // itself an explicit focus: that is the plan's own stated intent
        // for where focus lands, and both corrections exist only to fix up
        // focus the plan itself never addressed.
        if !Self.lastOpIsExplicitFocus(plan) {
            if focusNeedsRestore, let finalID = trackedFocusID {
                // `pane.move` never focuses the pane it moved (confirmed
                // live); restore focus only for the pane that held it
                // before the plan, and only once, at wherever the plan's
                // moves finally left it.
                await Self.bestEffortFocus(finalID, client: client, executed: &executed)
            } else if unzoomRan, let originalFocus = model.focusedPaneID {
                // herdr's pane.zoom focuses the pane it unzoomed and
                // switches the active workspace/tab to it (confirmed
                // against source), so an unzoom that ran without the
                // move-focus rule above already retargeting focus leaves
                // the wrong pane focused unless corrected here.
                await Self.bestEffortFocus(originalFocus, client: client, executed: &executed)
            }
        }

        let (moveInverseOps, moveIrreversible, positionLost) = tracker.buildInverseOps()
        irreversible.append(contentsOf: moveIrreversible)
        // A pane recreated in a brand-new tab (its own origin tab was a
        // single-pane tab herdr auto-closed once vacated) lands somewhere
        // that is correct only up to which workspace it is in -- the label
        // says so rather than implying an exact restore.
        let inverseLabel = positionLost ? "Undo \(plan.label) (into a new tab)" : "Undo \(plan.label)"
        let inverse = OpPlan(ops: moveInverseOps + simpleInverseOps, label: inverseLabel)
        return .success(ExecutedPlan(plan: plan, inverse: inverse, irreversible: irreversible, paneIDRemap: tracker.currentPaneIDMap, positionLost: positionLost))
    }

    private static func bestEffortFocus(_ pane: PaneID, client: HerdrClient, executed: inout [PrimitiveOp]) async {
        let focusOp = PrimitiveOp.focusPane(pane)
        guard (try? await client.perform(focusOp)) != nil else { return }
        executed.append(focusOp)
    }

    // MARK: - placeholder resolution / id threading

    /// `nil` when `op` carries a placeholder whose step never produced the
    /// id kind it needs -- the caller must fail the plan rather than let a
    /// sentinel string reach `perform`.
    private static func resolvePlaceholders(_ op: PrimitiveOp, results: [Int: OpResult]) -> PrimitiveOp? {
        func pane(_ id: PaneID) -> PaneID? {
            guard let step = id.planPlaceholderStep else { return id }
            return results[step]?.movedPaneNewID
        }
        func tab(_ id: TabID) -> TabID? {
            guard let step = id.planPlaceholderStep else { return id }
            return results[step]?.createdTabID
        }
        func optionalPane(_ id: PaneID?) -> PaneID?? {
            guard let id else { return .some(nil) }
            guard let resolved = pane(id) else { return nil }
            return .some(resolved)
        }
        switch op {
        case let .movePaneToTab(p, t, target, split, ratio):
            guard let p2 = pane(p), let t2 = tab(t), let target2 = optionalPane(target) else { return nil }
            return .movePaneToTab(p2, tab: t2, target: target2, split: split, ratio: ratio)
        case let .movePaneToNewTab(p, workspace, label):
            guard let p2 = pane(p) else { return nil }
            return .movePaneToNewTab(p2, workspace: workspace, label: label)
        case let .movePaneToNewWorkspace(p, label, tabLabel):
            guard let p2 = pane(p) else { return nil }
            return .movePaneToNewWorkspace(p2, label: label, tabLabel: tabLabel)
        case let .swapPanes(a, b):
            guard let a2 = pane(a), let b2 = pane(b) else { return nil }
            return .swapPanes(a2, b2)
        case let .setSplitRatio(t, path, ratio):
            guard let t2 = tab(t) else { return nil }
            return .setSplitRatio(tab: t2, path: path, ratio: ratio)
        case let .moveTab(t, insertIndex):
            guard let t2 = tab(t) else { return nil }
            return .moveTab(t2, insertIndex: insertIndex)
        case .moveWorkspace:
            return op
        case let .renamePane(p, label):
            guard let p2 = pane(p) else { return nil }
            return .renamePane(p2, label)
        case let .renameTab(t, label):
            guard let t2 = tab(t) else { return nil }
            return .renameTab(t2, label)
        case .renameWorkspace:
            return op
        case let .closePane(p):
            guard let p2 = pane(p) else { return nil }
            return .closePane(p2)
        case let .closeTab(t):
            guard let t2 = tab(t) else { return nil }
            return .closeTab(t2)
        case .closeWorkspace:
            return op
        case let .zoom(p, mode):
            guard let p2 = pane(p) else { return nil }
            return .zoom(p2, mode: mode)
        case let .focusPane(p):
            guard let p2 = pane(p) else { return nil }
            return .focusPane(p2)
        case let .focusTab(t):
            guard let t2 = tab(t) else { return nil }
            return .focusTab(t2)
        case .focusWorkspace:
            return op
        }
    }

    /// The pane a move op relocates, or `nil` for every op that does not move
    /// a pane -- the only ops the focus-follow rule, id-threading for
    /// `movedPaneNewID`, and move-origin tracking care about.
    private static func sourcePane(of op: PrimitiveOp) -> PaneID? {
        switch op {
        case let .movePaneToTab(p, _, _, _, _): return p
        case let .movePaneToNewTab(p, _, _): return p
        case let .movePaneToNewWorkspace(p, _, _): return p
        default: return nil
        }
    }

    private static func destinationTab(of op: PrimitiveOp, result: OpResult) -> TabID? {
        switch op {
        case let .movePaneToTab(_, tab, _, _, _): return tab
        case .movePaneToNewTab, .movePaneToNewWorkspace: return result.createdTabID
        default: return nil
        }
    }

    /// The workspace a move op's destination tab belongs to, used to decide
    /// whether a LATER inverse move crosses a workspace (and so must
    /// reference the pane via a placeholder rather than a literal id --
    /// see `MoveTracker.buildInverseOps`'s plain-move branch). `knownTabWorkspaces`
    /// covers a destination tab created earlier in THIS SAME plan (a
    /// migration's second-and-later panes landing in the first pane's new
    /// tab), which `model` -- the snapshot from before the plan ran -- has
    /// no record of at all.
    private static func destinationWorkspace(of op: PrimitiveOp, result: OpResult, model: SessionModel, knownTabWorkspaces: [TabID: WorkspaceID]) -> WorkspaceID? {
        switch op {
        case let .movePaneToNewTab(_, workspace, _):
            return workspace
        case .movePaneToNewWorkspace:
            return result.createdWorkspaceID
        case let .movePaneToTab(_, tab, _, _, _):
            if let known = knownTabWorkspaces[tab] { return known }
            return model.tabs.first { $0.value.contains { $0.tabID == tab } }?.key
        default:
            return nil
        }
    }

    private static func isCompensatingSwap(_ op: PrimitiveOp, tracker: MoveTracker) -> Bool {
        guard case let .swapPanes(a, b) = op else { return false }
        return tracker.isTrackingCurrentIdentity(a) || tracker.isTrackingCurrentIdentity(b)
    }

    private static func isCloseOp(_ op: PrimitiveOp) -> Bool {
        switch op {
        case .closePane, .closeTab, .closeWorkspace: return true
        default: return false
        }
    }

    /// A bounce's own cleanup `closeTab` (its target was always a
    /// placeholder, never a literal id a caller wrote by hand) is plumbing
    /// for a fully-reversible move, not a semantic loss of state -- so it is
    /// excluded from `ExecutedPlan.irreversible` even though it has no
    /// inverse op of its own.
    private static func isPlaceholderTabCleanup(_ rawOp: PrimitiveOp) -> Bool {
        if case let .closeTab(t) = rawOp { return t.planPlaceholderStep != nil }
        return false
    }

    /// Whether `plan`'s own last op already names an explicit focus target
    /// -- if so, that is the plan's own intent for where focus lands, and
    /// neither the focus-follow-a-moved-pane rule nor the unzoom-hijack
    /// correction may overrule it.
    private static func lastOpIsExplicitFocus(_ plan: OpPlan) -> Bool {
        switch plan.ops.last {
        case .focusPane, .focusTab, .focusWorkspace: return true
        default: return false
        }
    }

    private static func unzoomTarget(forTab tabID: TabID, model: SessionModel) -> PaneID? {
        guard let layout = model.layouts[tabID] else { return nil }
        return layout.focusedPaneID ?? layout.panes.first?.paneID
    }

    private static func isTabNotFound(_ error: Error) -> Bool {
        guard case let .other(code, _)? = error as? HerdrOpError else { return false }
        return code == "tab_not_found"
    }

    private static func describe(_ error: Error) -> (code: String, message: String) {
        if let opError = error as? HerdrOpError {
            switch opError {
            case .sameTab: return ("same_tab", "same_tab")
            case .crossTab: return ("cross_tab", "cross_tab")
            case .zoomedTab: return ("zoomed_tab", "zoomed_tab")
            case .workspaceGroupCloseRequired: return ("workspace_group_close_required", "workspace_group_close_required")
            case let .other(code, message): return (code, message)
            }
        }
        if let clientError = error as? HerdrClientError {
            switch clientError {
            case let .server(code, message): return (code, message)
            case let .transport(message): return ("transport_error", message)
            case let .protocolTooOld(found, required): return ("protocol_too_old", "found \(found), required \(required)")
            }
        }
        return ("unknown_error", String(describing: error))
    }

    // MARK: - non-move inverses (built immediately, in reverse-chronological order)

    /// The reverse of one non-move op, or `nil` when `op` moves a pane (see
    /// `MoveTracker`, which builds those semantically instead) or has no
    /// meaningful reverse at all (close/zoom/focus). Reads whatever "prior"
    /// value it needs from `model` -- the snapshot as it stood before the
    /// whole plan started.
    private static func simpleInverse(for op: PrimitiveOp, model: SessionModel) -> PrimitiveOp? {
        switch op {
        case .movePaneToTab, .movePaneToNewTab, .movePaneToNewWorkspace:
            return nil

        case let .swapPanes(a, b):
            return .swapPanes(a, b)

        case let .setSplitRatio(tab, path, _):
            guard let priorRatio = priorSplitRatio(tab: tab, path: path, model: model) else { return nil }
            return .setSplitRatio(tab: tab, path: path, ratio: priorRatio)

        case let .moveTab(tab, insertIndex):
            guard let workspaceID = workspaceContaining(tab: tab, model: model),
                  let priorIndex = model.tabs[workspaceID]?.firstIndex(where: { $0.tabID == tab })
            else { return nil }
            return .moveTab(tab, insertIndex: inverseInsertIndex(priorIndex: priorIndex, forwardInsertIndex: insertIndex))

        case let .moveWorkspace(workspace, insertIndex):
            guard let priorIndex = model.workspaces.firstIndex(where: { $0.workspaceID == workspace }) else { return nil }
            return .moveWorkspace(workspace, insertIndex: inverseInsertIndex(priorIndex: priorIndex, forwardInsertIndex: insertIndex))

        case let .renamePane(pane, _):
            return .renamePane(pane, model.panes[pane]?.label)

        case let .renameTab(tab, _):
            guard let priorLabel = model.tabs.values.flatMap({ $0 }).first(where: { $0.tabID == tab })?.label else { return nil }
            return .renameTab(tab, priorLabel)

        case let .renameWorkspace(workspace, _):
            guard let priorLabel = model.workspaces.first(where: { $0.workspaceID == workspace })?.label else { return nil }
            return .renameWorkspace(workspace, priorLabel)

        case .closePane, .closeTab, .closeWorkspace:
            // No inverse: herdr has no "recreate with this exact id" verb, so
            // fabricating one here would just be a lie the undo journal
            // trusts. The omission itself is the honest representation --
            // reflected in `ExecutedPlan.irreversible`.
            return nil

        case .zoom, .focusPane, .focusTab, .focusWorkspace:
            return nil
        }
    }

    /// herdr's `tab.move`/`workspace.move` treat `insertIndex` as a position
    /// in the list with the moved item already removed: the actual
    /// resulting index is `insert - 1` when the item's prior index was
    /// before `insert`, else `insert` outright (source: herdr's own
    /// `workspace.rs`/`actions.rs`). To land back at `priorIndex`, the
    /// inverse's own `insertIndex` must overshoot by one whenever the
    /// forward move actually left the item before its original spot.
    private static func inverseInsertIndex(priorIndex: Int, forwardInsertIndex: Int) -> Int {
        let actualCurrentIndex = gapAdjustedResultIndex(source: priorIndex, insert: forwardInsertIndex)
        return actualCurrentIndex < priorIndex ? priorIndex + 1 : priorIndex
    }

    private static func gapAdjustedResultIndex(source: Int, insert: Int) -> Int {
        source < insert ? insert - 1 : insert
    }

    private static func priorSplitRatio(tab: TabID, path: [Bool], model: SessionModel) -> Double? {
        guard let layout = model.layouts[tab] else { return nil }
        guard var current = layout.splits.first(where: { $0.rect == layout.area })
            ?? layout.splits.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })
        else { return nil }
        for branch in path {
            let (first, second) = childRegions(of: current.rect, direction: current.direction, ratio: current.ratio)
            let target = branch ? second : first
            guard let next = layout.splits.first(where: { $0.rect == target }) else { return nil }
            current = next
        }
        return current.ratio
    }

    private static func workspaceContaining(tab: TabID, model: SessionModel) -> WorkspaceID? {
        model.tabs.first { $0.value.contains { $0.tabID == tab } }?.key
    }

    /// Shared by every prior-position/prior-ratio lookup: splits a rect into
    /// its two child regions for a direction/ratio, matching herdr's own
    /// cell-grid rounding (`GesturePlanner.SplitTree`/`CanvasGeometry` apply
    /// the identical formula; duplicated here rather than shared because it
    /// is a three-line, dependency-free piece of geometry, not a seam worth
    /// coupling three unrelated files over).
    fileprivate static func childRegions(of rect: CellRect, direction: SplitDirection, ratio: Double) -> (first: CellRect, second: CellRect) {
        switch direction {
        case .right:
            let firstWidth = Int((Double(rect.width) * ratio).rounded())
            let first = CellRect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height)
            let second = CellRect(x: rect.x + firstWidth, y: rect.y, width: rect.width - firstWidth, height: rect.height)
            return (first, second)
        case .down:
            let firstHeight = Int((Double(rect.height) * ratio).rounded())
            let first = CellRect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight)
            let second = CellRect(x: rect.x, y: rect.y + firstHeight, width: rect.width, height: rect.height - firstHeight)
            return (first, second)
        }
    }
}

/// One pane's recorded position before any op in this plan moved it: its
/// tab and workspace, its neighbor in whatever split it shared (`nil` for a
/// single-pane tab), that split's direction and ratio, and which side of
/// the split the pane itself occupied -- `wasFirstChild` -- since
/// `movePaneToTab`'s default landing always puts the MOVED pane on the
/// second/right(or bottom) side, so reconstructing a pane that started on
/// the first/left(or top) side needs a trailing `swapPanes` to flip it back.
private struct PaneOrigin {
    let workspaceID: WorkspaceID
    let tabID: TabID
    let neighborPaneID: PaneID?
    let split: SplitDirection
    let ratio: Double?
    let wasFirstChild: Bool
    let stepIndex: Int
}

/// Accumulates every pane a plan moved, deduped to each pane's FIRST
/// recorded origin (a same-tab bounce moves the same literal pane id twice;
/// only the first sighting is the true "before this plan" position), and
/// builds the semantic inverse once the plan finishes running. Kept as its
/// own value type rather than inline in `execute` because the origin ->
/// current-position bookkeeping and the three inverse shapes it can produce
/// (bounce / plain move / migration-into-a-new-tab) are a self-contained
/// concern.
private struct MoveTracker {
    private var origins: [PaneID: PaneOrigin] = [:]
    private var originKeyForStep: [Int: PaneID] = [:]
    private var currentPaneID: [PaneID: PaneID] = [:]
    private var currentTabID: [PaneID: TabID] = [:]
    private var currentWorkspaceID: [PaneID: WorkspaceID] = [:]
    private var knownTabWorkspaces: [TabID: WorkspaceID] = [:]
    // Every resolved move op recorded against each origin key, in the order
    // it ran -- read only when that key's group turns out irreversible (its
    // origin tab's tree could not be rebuilt), to report exactly which
    // forward ops the caller must treat as having no inverse.
    private var movedOpsByOriginKey: [PaneID: [PrimitiveOp]] = [:]
    // The origin tab's own split tree, captured once (from the model as it
    // stood before the plan ran) the first time any of its panes is
    // recorded -- the tree a multi-pane group's migration-shaped inverse
    // replays (see `buildInverseOps`), never a pairwise neighbor guess.
    private var treeByOriginTab: [TabID: SplitTree] = [:]

    /// Called after a move op (`movePaneToTab`/`movePaneToNewTab`/
    /// `movePaneToNewWorkspace`) succeeds. `rawOp`'s own (pre-resolution)
    /// source tells us whether this step moved a pane this tracker has
    /// already seen (a placeholder naming an earlier step) or a pane seen
    /// for the first time (a literal id, whether brand new or a same-tab
    /// bounce's second hop reusing the same literal id).
    mutating func record(rawOp: PrimitiveOp, resolvedOp: PrimitiveOp, resolvedSource: PaneID, result: OpResult, stepIndex: Int, model: SessionModel) {
        let rawSource = MutationEngine.sourcePaneForTracking(of: rawOp)
        let originKey: PaneID?
        if let step = rawSource?.planPlaceholderStep {
            originKey = originKeyForStep[step]
        } else if let rawSource {
            if origins[rawSource] == nil {
                origins[rawSource] = Self.recordOrigin(of: rawSource, model: model, stepIndex: stepIndex)
                if let tabID = origins[rawSource]?.tabID, treeByOriginTab[tabID] == nil, let layout = model.layouts[tabID] {
                    treeByOriginTab[tabID] = SplitTree.build(from: layout)
                }
            }
            originKey = rawSource
        } else {
            originKey = nil
        }
        guard let originKey else { return }
        originKeyForStep[stepIndex] = originKey
        movedOpsByOriginKey[originKey, default: []].append(resolvedOp)
        currentPaneID[originKey] = result.movedPaneNewID ?? resolvedSource
        if let tab = MutationEngine.destinationTabForTracking(of: resolvedOp, result: result) {
            currentTabID[originKey] = tab
            if let workspace = MutationEngine.destinationWorkspaceForTracking(of: resolvedOp, result: result, model: model, knownTabWorkspaces: knownTabWorkspaces) {
                currentWorkspaceID[originKey] = workspace
                knownTabWorkspaces[tab] = workspace
            }
        }
    }

    var isEmpty: Bool { origins.isEmpty }

    /// Every tracked pane's origin (pre-plan) literal id mapped to its
    /// current (post-plan) id -- `ExecutedPlan.paneIDRemap`'s source.
    var currentPaneIDMap: [PaneID: PaneID] { currentPaneID }

    /// Whether `pane` is the CURRENT resolved identity of some pane this
    /// plan already moved -- used to recognize a compensating swap that
    /// belongs to that same move, not a standalone one.
    func isTrackingCurrentIdentity(_ pane: PaneID) -> Bool {
        currentPaneID.values.contains(pane)
    }

    /// The semantic inverse for every tracked pane, grouped by the tab each
    /// one started in, plus every move op that turned out to have no
    /// inverse (see below). A group of more than one pane sharing an origin
    /// tab can only come from a tab migration, which evacuates that tab
    /// entirely -- herdr auto-closes it once its last pane leaves, so that
    /// origin tab id is dead by the time any inverse plan could run, and the
    /// honest reconstruction replays the origin tab's own split tree
    /// (`migrationInverseOps`) into a brand-new tab in the original
    /// workspace, never a `movePaneToTab` back into the vacated id and never
    /// a naive per-pane sibling guess (a 3+-pane tree's pairwise "neighbor"
    /// is not always still IN the new tab at the moment a later pane's
    /// inverse move would need it as a target). When that tree cannot be
    /// rebuilt at all (a hand-built plan whose model never carried a layout
    /// for the origin tab, or one that later drifted out from under it),
    /// this reports no inverse for the whole group rather than guess at a
    /// shape: replaying pairwise sibling records without the real tree can
    /// target a pane not yet present in the new tab (herdr rejects that) or
    /// land the pane in the wrong place without herdr ever objecting, which
    /// is worse. A single pane whose final tab is its own origin tab is the
    /// same-tab bounce case: herdr refuses a same-tab `pane.move` outright,
    /// so that also needs the temp-tab dance, not a direct move. Every other
    /// single-pane case is a plain cross-tab move back UNLESS the origin tab
    /// held only that one pane -- herdr auto-closes a tab the instant its
    /// last pane leaves, so a single-pane origin tab is exactly as dead by
    /// undo time as a migration's origin tab is, and gets the same
    /// recreate-in-a-new-tab treatment (`positionLost` tells the caller so
    /// the inverse's label can say position/identity was not restored).
    func buildInverseOps() -> (ops: [PrimitiveOp], irreversible: [PrimitiveOp], positionLost: Bool) {
        guard !origins.isEmpty else { return ([], [], false) }
        func remap(_ id: PaneID?) -> PaneID? {
            guard let id else { return nil }
            return currentPaneID[id] ?? id
        }

        var ops: [PrimitiveOp] = []
        var irreversible: [PrimitiveOp] = []
        var positionLost = false
        let groups = Dictionary(grouping: origins.keys, by: { origins[$0]!.tabID })
        for (originTabID, keysInGroup) in groups.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sortedKeys = keysInGroup.sorted { origins[$0]!.stepIndex < origins[$1]!.stepIndex }
            guard let firstKey = sortedKeys.first,
                  let firstOrigin = origins[firstKey],
                  let firstFinalID = currentPaneID[firstKey]
            else { continue }

            if sortedKeys.count > 1 {
                guard let tree = treeByOriginTab[originTabID] else {
                    for key in sortedKeys {
                        irreversible.append(contentsOf: movedOpsByOriginKey[key] ?? [])
                    }
                    continue
                }
                // A fresh sub-plan of its own: its placeholders are built
                // relative to ITS OWN position 0, so they must be shifted by
                // wherever this group actually lands in the combined array
                // before being appended -- see `shiftPlaceholders`.
                let localOps = Self.migrationInverseOps(tree: tree, workspaceID: firstOrigin.workspaceID) { currentPaneID[$0] ?? $0 }
                ops.append(contentsOf: Self.shiftPlaceholders(in: localOps, by: ops.count))
            } else if currentTabID[firstKey] == originTabID {
                let tempStep = ops.count
                ops.append(.movePaneToNewTab(firstFinalID, workspace: firstOrigin.workspaceID, label: nil))
                ops.append(.movePaneToTab(firstFinalID, tab: originTabID, target: remap(firstOrigin.neighborPaneID), split: firstOrigin.split, ratio: firstOrigin.ratio))
                ops.append(.closeTab(TabID.planPlaceholder(createdByStep: tempStep)))
                if firstOrigin.wasFirstChild, let neighbor = remap(firstOrigin.neighborPaneID) {
                    // A same-workspace bounce (this branch fires only when
                    // the pane comes back to its OWN origin tab) never
                    // re-keys the pane, so the literal id is safe here.
                    ops.append(.swapPanes(firstFinalID, neighbor))
                }
            } else if case .pane = treeByOriginTab[originTabID] {
                // The origin tab held only this pane -- it is dead now, the
                // same reason a migration's origin tab is dead, so this
                // gets the same fix: recreate a fresh tab in the origin
                // workspace rather than target the vacated id. No sibling
                // ever existed in a single-pane tab, so no trailing swap.
                ops.append(.movePaneToNewTab(firstFinalID, workspace: firstOrigin.workspaceID, label: nil))
                positionLost = true
            } else {
                let moveStep = ops.count
                ops.append(.movePaneToTab(firstFinalID, tab: originTabID, target: remap(firstOrigin.neighborPaneID), split: firstOrigin.split, ratio: firstOrigin.ratio))
                if firstOrigin.wasFirstChild, let neighbor = remap(firstOrigin.neighborPaneID) {
                    // Unlike the bounce, this move CAN cross back into a
                    // different workspace than wherever the pane currently
                    // sits -- and a cross-workspace move re-keys the pane,
                    // so a later reference to it (this swap) must go
                    // through a placeholder naming this same step, exactly
                    // as the forward planner's own contract requires,
                    // rather than a literal id that may already be stale by
                    // the time this inverse actually runs. Default to
                    // "crosses" when the destination workspace was never
                    // tracked, since a placeholder always resolves safely
                    // even when nothing actually changed.
                    let crossesWorkspace = currentWorkspaceID[firstKey].map { $0 != firstOrigin.workspaceID } ?? true
                    let mover = crossesWorkspace ? PaneID.planPlaceholder(movedByStep: moveStep) : firstFinalID
                    ops.append(.swapPanes(mover, neighbor))
                }
            }
        }
        return (ops, irreversible, positionLost)
    }

    /// Replays `tree` -- the origin tab's own split shape, captured before
    /// the plan ran -- into a brand-new tab in `workspaceID`, using exactly
    /// the same anchor/pre-order algorithm `GesturePlanner`'s forward
    /// migration planning uses (`materialize`), with `remap` substituting
    /// each leaf's original id for its current resolved one. Every anchor
    /// reference beyond the very first op is a placeholder naming ITS OWN
    /// step, never a literal: the first op's own move crosses back into
    /// `workspaceID`, which re-keys that pane, so anything referencing it
    /// afterward must resolve fresh rather than trust a value computed
    /// before this reconstruction even started.
    private static func migrationInverseOps(tree: SplitTree, workspaceID: WorkspaceID, remap: (PaneID) -> PaneID) -> [PrimitiveOp] {
        var ops: [PrimitiveOp] = [.movePaneToNewTab(remap(tree.leftmostPaneID), workspace: workspaceID, label: nil)]
        let destinationTab = TabID.planPlaceholder(createdByStep: 0)
        let rootAnchor = PaneID.planPlaceholder(movedByStep: 0)
        materializeInverse(tree, anchor: rootAnchor, destinationTab: destinationTab, remap: remap, ops: &ops)
        return ops
    }

    private static func materializeInverse(_ node: SplitTree, anchor: PaneID, destinationTab: TabID, remap: (PaneID) -> PaneID, ops: inout [PrimitiveOp]) {
        guard case let .split(direction, ratio, first, second) = node else { return }
        let secondPaneID = remap(second.leftmostPaneID)
        let thisStep = ops.count
        ops.append(.movePaneToTab(secondPaneID, tab: destinationTab, target: anchor, split: direction, ratio: ratio))
        let secondAnchor = PaneID.planPlaceholder(movedByStep: thisStep)
        materializeInverse(first, anchor: anchor, destinationTab: destinationTab, remap: remap, ops: &ops)
        materializeInverse(second, anchor: secondAnchor, destinationTab: destinationTab, remap: remap, ops: &ops)
    }

    /// Rewrites every placeholder id embedded in `ops` (built as if it were
    /// its own plan starting at step 0) to instead name step `original +
    /// offset` -- what actually reaching that op's step index in the
    /// COMBINED inverse plan requires, since a placeholder's step number is
    /// only meaningful relative to the array it will finally execute in.
    private static func shiftPlaceholders(in ops: [PrimitiveOp], by offset: Int) -> [PrimitiveOp] {
        guard offset != 0 else { return ops }
        func pane(_ id: PaneID) -> PaneID {
            guard let step = id.planPlaceholderStep else { return id }
            return .planPlaceholder(movedByStep: step + offset)
        }
        func tab(_ id: TabID) -> TabID {
            guard let step = id.planPlaceholderStep else { return id }
            return .planPlaceholder(createdByStep: step + offset)
        }
        return ops.map { op in
            switch op {
            case let .movePaneToTab(p, t, target, split, ratio):
                return .movePaneToTab(pane(p), tab: tab(t), target: target.map(pane), split: split, ratio: ratio)
            case let .movePaneToNewTab(p, workspace, label):
                return .movePaneToNewTab(pane(p), workspace: workspace, label: label)
            case let .movePaneToNewWorkspace(p, label, tabLabel):
                return .movePaneToNewWorkspace(pane(p), label: label, tabLabel: tabLabel)
            case let .swapPanes(a, b):
                return .swapPanes(pane(a), pane(b))
            case let .closeTab(t):
                return .closeTab(tab(t))
            default:
                return op
            }
        }
    }

    private static func recordOrigin(of pane: PaneID, model: SessionModel, stepIndex: Int) -> PaneOrigin? {
        guard let record = model.panes[pane] else { return nil }
        guard let layout = model.layouts[record.tabID],
              let paneRect = layout.panes.first(where: { $0.paneID == pane })?.rect
        else {
            return PaneOrigin(workspaceID: record.workspaceID, tabID: record.tabID, neighborPaneID: nil, split: .right, ratio: nil, wasFirstChild: false, stepIndex: stepIndex)
        }
        for split in layout.splits {
            let (first, second) = MutationEngine.childRegions(of: split.rect, direction: split.direction, ratio: split.ratio)
            if first == paneRect {
                return PaneOrigin(
                    workspaceID: record.workspaceID, tabID: record.tabID, neighborPaneID: anyPane(inRect: second, layout: layout),
                    split: split.direction, ratio: split.ratio, wasFirstChild: true, stepIndex: stepIndex
                )
            }
            if second == paneRect {
                return PaneOrigin(
                    workspaceID: record.workspaceID, tabID: record.tabID, neighborPaneID: anyPane(inRect: first, layout: layout),
                    split: split.direction, ratio: split.ratio, wasFirstChild: false, stepIndex: stepIndex
                )
            }
        }
        return PaneOrigin(workspaceID: record.workspaceID, tabID: record.tabID, neighborPaneID: nil, split: .right, ratio: nil, wasFirstChild: false, stepIndex: stepIndex)
    }

    /// Some pane occupying `rect`, descending into a further split's first
    /// child when `rect` isn't a leaf -- consistent with the leftmost-anchor
    /// convention `GesturePlanner`'s tab-migration planning already uses, and
    /// good enough for "a" neighbor to split back against; the undo is a
    /// best-effort restore of position, not a pixel-exact one.
    private static func anyPane(inRect rect: CellRect, layout: LayoutSnapshot) -> PaneID? {
        if let direct = layout.panes.first(where: { $0.rect == rect }) { return direct.paneID }
        guard let split = layout.splits.first(where: { $0.rect == rect }) else { return nil }
        let (first, _) = MutationEngine.childRegions(of: split.rect, direction: split.direction, ratio: split.ratio)
        return anyPane(inRect: first, layout: layout)
    }
}

extension MutationEngine {
    fileprivate static func sourcePaneForTracking(of op: PrimitiveOp) -> PaneID? { sourcePane(of: op) }
    fileprivate static func destinationTabForTracking(of op: PrimitiveOp, result: OpResult) -> TabID? { destinationTab(of: op, result: result) }
    fileprivate static func destinationWorkspaceForTracking(
        of op: PrimitiveOp, result: OpResult, model: SessionModel, knownTabWorkspaces: [TabID: WorkspaceID]
    ) -> WorkspaceID? {
        destinationWorkspace(of: op, result: result, model: model, knownTabWorkspaces: knownTabWorkspaces)
    }
}
