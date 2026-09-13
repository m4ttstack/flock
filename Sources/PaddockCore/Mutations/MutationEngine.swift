import Foundation

/// What `MutationEngine.execute` produced: the plan as it actually ran
/// (placeholders resolved) and the inverse built from those resolved ids.
/// `inverse.ops` omits any op with no meaningful reverse (see `closePane`/
/// `closeTab`/`closeWorkspace` in `MutationEngine.inverse(for:result:model:)`)
/// rather than inventing a recreate op herdr has no way to satisfy; Task 22's
/// undo journal reads that omission as this plan being partially irreversible.
public struct ExecutedPlan: Equatable, Sendable {
    public let plan: OpPlan
    public let inverse: OpPlan

    public init(plan: OpPlan, inverse: OpPlan) {
        self.plan = plan
        self.inverse = inverse
    }
}

/// Reported when `perform` throws partway through a plan. `executed` is every
/// op (unzoom included) that actually reached herdr before `failedOp`, in the
/// order it ran -- the executor never rolls these back itself; the store
/// converges on the real events those ops caused and the failure surfaces to
/// the UI as-is.
public struct OpFailure: Error, Equatable, Sendable {
    public let failedOp: PrimitiveOp
    public let code: String
    public let message: String
    public let executed: [PrimitiveOp]

    public init(failedOp: PrimitiveOp, code: String, message: String, executed: [PrimitiveOp]) {
        self.failedOp = failedOp
        self.code = code
        self.message = message
        self.executed = executed
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

        for tabID in plan.needsUnzoom {
            guard let pane = Self.unzoomTarget(forTab: tabID, model: model) else { continue }
            let op = PrimitiveOp.zoom(pane, mode: .off)
            do {
                _ = try await client.perform(op)
                executed.append(op)
            } catch {
                let (code, message) = Self.describe(error)
                return .failure(OpFailure(failedOp: op, code: code, message: message, executed: executed))
            }
        }

        var results: [Int: OpResult] = [:]
        var inverseOps: [PrimitiveOp] = []
        // Tracks the pane that was focused before the plan ran, forwarded
        // through every hop a move op gives it, so the executor can tell
        // whether the plan's own moves ever touched it -- see `sourcePane`.
        var trackedFocusID = model.focusedPaneID
        var focusNeedsRestore = false

        for (index, rawOp) in plan.ops.enumerated() {
            let op = Self.resolvePlaceholders(rawOp, results: results)

            if let source = Self.sourcePane(of: op), let tracked = trackedFocusID, source == tracked {
                focusNeedsRestore = true
            }

            do {
                let result = try await client.perform(op)
                results[index] = result
                executed.append(op)
                if let source = Self.sourcePane(of: op), let newID = result.movedPaneNewID, source == trackedFocusID {
                    trackedFocusID = newID
                }
                if let inverseOp = Self.inverse(for: op, result: result, model: model) {
                    inverseOps.insert(inverseOp, at: 0)
                }
            } catch {
                if case .closeTab = op, Self.isTabNotFound(error) {
                    // Spike 3: herdr auto-closes a bounce plan's temp tab the
                    // instant its last pane leaves, so this closeTab is
                    // routinely a no-op cleanup arriving too late to find its
                    // target -- that is success, not a failure to report.
                    executed.append(op)
                    continue
                }
                let (code, message) = Self.describe(error)
                return .failure(OpFailure(failedOp: op, code: code, message: message, executed: executed))
            }
        }

        if focusNeedsRestore, let finalID = trackedFocusID {
            // `pane.move` never focuses the pane it moved (confirmed live);
            // restore focus only for the pane that held it before the plan,
            // and only once, at wherever the plan's moves finally left it.
            let focusOp = PrimitiveOp.focusPane(finalID)
            _ = try? await client.perform(focusOp)
            executed.append(focusOp)
        }

        return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: inverseOps, label: "Undo \(plan.label)")))
    }

    // MARK: - placeholder resolution / id threading

    private static func resolvePlaceholders(_ op: PrimitiveOp, results: [Int: OpResult]) -> PrimitiveOp {
        func pane(_ id: PaneID) -> PaneID {
            guard let step = id.planPlaceholderStep, let resolved = results[step]?.movedPaneNewID else { return id }
            return resolved
        }
        func tab(_ id: TabID) -> TabID {
            guard let step = id.planPlaceholderStep, let resolved = results[step]?.createdTabID else { return id }
            return resolved
        }
        switch op {
        case let .movePaneToTab(p, t, target, split, ratio):
            return .movePaneToTab(pane(p), tab: tab(t), target: target.map(pane), split: split, ratio: ratio)
        case let .movePaneToNewTab(p, workspace, label):
            return .movePaneToNewTab(pane(p), workspace: workspace, label: label)
        case let .movePaneToNewWorkspace(p, label, tabLabel):
            return .movePaneToNewWorkspace(pane(p), label: label, tabLabel: tabLabel)
        case let .swapPanes(a, b):
            return .swapPanes(pane(a), pane(b))
        case let .setSplitRatio(t, path, ratio):
            return .setSplitRatio(tab: tab(t), path: path, ratio: ratio)
        case let .moveTab(t, insertIndex):
            return .moveTab(tab(t), insertIndex: insertIndex)
        case .moveWorkspace:
            return op
        case let .renamePane(p, label):
            return .renamePane(pane(p), label)
        case let .renameTab(t, label):
            return .renameTab(tab(t), label)
        case .renameWorkspace:
            return op
        case let .closePane(p):
            return .closePane(pane(p))
        case let .closeTab(t):
            return .closeTab(tab(t))
        case .closeWorkspace:
            return op
        case let .zoom(p, mode):
            return .zoom(pane(p), mode: mode)
        case let .focusPane(p):
            return .focusPane(pane(p))
        case let .focusTab(t):
            return .focusTab(tab(t))
        case .focusWorkspace:
            return op
        }
    }

    /// The pane a move op relocates, or `nil` for every op that does not move
    /// a pane -- the only ops the focus-follow rule and id-threading for
    /// `movedPaneNewID` care about.
    private static func sourcePane(of op: PrimitiveOp) -> PaneID? {
        switch op {
        case let .movePaneToTab(p, _, _, _, _): return p
        case let .movePaneToNewTab(p, _, _): return p
        case let .movePaneToNewWorkspace(p, _, _): return p
        default: return nil
        }
    }

    private static func unzoomTarget(forTab tabID: TabID, model: SessionModel) -> PaneID? {
        if let focused = model.layouts[tabID]?.focusedPaneID { return focused }
        return model.panes.values.first { $0.tabID == tabID }?.paneID
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

    // MARK: - inverse construction

    /// One op's reverse, built from `op` (already placeholder-resolved) and
    /// `result`, reading whatever "prior" value it needs from `model` -- the
    /// snapshot as it stood before this whole plan started, per the brief:
    /// every inverse in a plan is computed against that same starting point,
    /// never a running shadow of intermediate state. For the single-op plans
    /// every current gesture produces this is exact; a plan that moves the
    /// same pane more than once (the same-tab bounce, tab migration) yields
    /// one inverse per move, each aimed at that pane's true original
    /// position -- redundant in count but not wrong in effect, and resolving
    /// that redundancy against a live model is Task 22's undo-journal
    /// concern, not this executor's.
    private static func inverse(for op: PrimitiveOp, result: OpResult, model: SessionModel) -> PrimitiveOp? {
        switch op {
        case let .movePaneToTab(pane, _, _, _, _),
             let .movePaneToNewTab(pane, _, _),
             let .movePaneToNewWorkspace(pane, _, _):
            guard let prior = priorPosition(of: pane, model: model) else { return nil }
            let movedID = result.movedPaneNewID ?? pane
            return .movePaneToTab(movedID, tab: prior.tabID, target: prior.neighborPaneID, split: prior.split, ratio: prior.ratio)

        case let .swapPanes(a, b):
            return .swapPanes(a, b)

        case let .setSplitRatio(tab, path, _):
            guard let priorRatio = priorSplitRatio(tab: tab, path: path, model: model) else { return nil }
            return .setSplitRatio(tab: tab, path: path, ratio: priorRatio)

        case let .moveTab(tab, _):
            guard let workspaceID = workspaceContaining(tab: tab, model: model),
                  let priorIndex = model.tabs[workspaceID]?.firstIndex(where: { $0.tabID == tab })
            else { return nil }
            return .moveTab(tab, insertIndex: priorIndex)

        case let .moveWorkspace(workspace, _):
            guard let priorIndex = model.workspaces.firstIndex(where: { $0.workspaceID == workspace }) else { return nil }
            return .moveWorkspace(workspace, insertIndex: priorIndex)

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
            // Task 22 reads a plan short an inverse for one of its ops as
            // partially irreversible.
            return nil

        case .zoom, .focusPane, .focusTab, .focusWorkspace:
            return nil
        }
    }

    private struct PriorPanePosition {
        let tabID: TabID
        let neighborPaneID: PaneID?
        let split: SplitDirection
        let ratio: Double?
    }

    /// Where `pane` sat before the plan ran: its tab, plus -- when it shared
    /// a split with exactly one sibling region -- that sibling's pane, the
    /// split's direction, and its ratio. A single-pane tab (no split touches
    /// its rect) yields no neighbor; `target: nil` for that case is the same
    /// legitimate omission `PrimitiveOp.movePaneToTab` already documents
    /// (herdr resolves it to the destination tab's own focused pane).
    private static func priorPosition(of pane: PaneID, model: SessionModel) -> PriorPanePosition? {
        guard let record = model.panes[pane] else { return nil }
        guard let layout = model.layouts[record.tabID],
              let paneRect = layout.panes.first(where: { $0.paneID == pane })?.rect
        else {
            return PriorPanePosition(tabID: record.tabID, neighborPaneID: nil, split: .right, ratio: nil)
        }
        for split in layout.splits {
            let (first, second) = childRegions(of: split.rect, direction: split.direction, ratio: split.ratio)
            if first == paneRect {
                return PriorPanePosition(tabID: record.tabID, neighborPaneID: anyPane(inRect: second, layout: layout), split: split.direction, ratio: split.ratio)
            }
            if second == paneRect {
                return PriorPanePosition(tabID: record.tabID, neighborPaneID: anyPane(inRect: first, layout: layout), split: split.direction, ratio: split.ratio)
            }
        }
        return PriorPanePosition(tabID: record.tabID, neighborPaneID: nil, split: .right, ratio: nil)
    }

    /// Some pane occupying `rect`, descending into a further split's first
    /// child when `rect` isn't a leaf -- consistent with the leftmost-anchor
    /// convention `GesturePlanner`'s tab-migration planning already uses, and
    /// good enough for "a" neighbor to split back against; the undo is a
    /// best-effort restore of position, not a pixel-exact one.
    private static func anyPane(inRect rect: CellRect, layout: LayoutSnapshot) -> PaneID? {
        if let direct = layout.panes.first(where: { $0.rect == rect }) { return direct.paneID }
        guard let split = layout.splits.first(where: { $0.rect == rect }) else { return nil }
        let (first, _) = childRegions(of: split.rect, direction: split.direction, ratio: split.ratio)
        return anyPane(inRect: first, layout: layout)
    }

    /// The ratio `setSplitRatio`'s own `path` (herdr's split-tree path: false
    /// = first child, true = second) pointed at before this op ran, walked
    /// down `LayoutSnapshot.splits` by rect containment the same way
    /// `CanvasGeometry`'s rect-derived fallback resolves paths for dividers.
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

    /// Shared by every prior-position/prior-ratio lookup above: splits a rect
    /// into its two child regions for a direction/ratio, matching herdr's own
    /// cell-grid rounding (`GesturePlanner.SplitTree`/`CanvasGeometry` apply
    /// the identical formula; duplicated here rather than shared because it
    /// is a three-line, dependency-free piece of geometry, not a seam worth
    /// coupling three unrelated files over).
    private static func childRegions(of rect: CellRect, direction: SplitDirection, ratio: Double) -> (first: CellRect, second: CellRect) {
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
