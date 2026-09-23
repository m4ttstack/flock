import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case connecting
    case live
    case reconnecting(attempt: Int)
    case unsupported(HerdrClientError)
}

extension HerdrClientError: Equatable {
    public static func == (lhs: HerdrClientError, rhs: HerdrClientError) -> Bool {
        switch (lhs, rhs) {
        case (.protocolTooOld(let lf, let lr), .protocolTooOld(let rf, let rr)):
            return lf == rf && lr == rr
        case (.server(let lc, let lm), .server(let rc, let rm)):
            return lc == rc && lm == rm
        case (.transport(let l), .transport(let r)):
            return l == r
        case (.timedOut(let l), .timedOut(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// Drives the herdr api socket per the spec's bootstrap dance: subscribe
/// (connection A, read-only for its whole life), buffer pushed events,
/// snapshot (connection B), install, replay the buffer, then stream live.
/// A stream end or transport error re-runs the whole dance with capped
/// backoff; `resnapshotInterval` periodically replaces the model wholesale
/// as a backstop against the server's 512-event ring having no gap signal.
@MainActor
@Observable
public final class HerdrStore {
    public private(set) var model: SessionModel?
    public private(set) var connection: ConnectionState = .connecting

    private let socketPath: String
    private let resnapshotInterval: Duration
    private let backoffSchedule: (Int) -> Duration
    /// How long an optimistic overlay waits for the live event that confirms
    /// its plan landed before reverting and re-snapshotting. A confirming
    /// event for an op herdr accepted comes back over a local socket in
    /// milliseconds, so the width is headroom: too narrow and a busy server's
    /// late event costs a revert, a re-snapshot and a layout that visibly
    /// snaps back and then forward again over an op that did land. Too wide
    /// and an op herdr accepted but never confirmed leaves the canvas showing
    /// a layout herdr does not have for that whole window, with only the
    /// `resnapshotInterval` backstop behind it.
    private let overlayConvergenceTimeout: Duration
    /// Passed to every `HerdrClient` this store makes, so a test can drive the
    /// no-answer path without waiting out the real deadline.
    private let requestTimeout: Duration

    private var runLoopTask: Task<Void, Never>?
    private var activeSubscribeSocket: LineSocket?
    private var reconnectAttempt = 0

    // Every `execute` bumps this before publishing its overlay; a pending
    // convergence watch checks its own snapshot against the current value
    // before touching `model`, so a superseded watch (a second `execute`
    // fired before the first converged) can never stomp the newer overlay.
    private var overlayGeneration = 0
    private var pendingConvergence: PendingConvergence?
    private var convergenceContinuation: (generation: Int, continuation: CheckedContinuation<Bool, Never>)?
    private var resolvedConvergence: [Int: Bool] = [:]
    private var isStopped = false

    /// Test seam only: production code never reads this. `resolvedConvergence`
    /// should hold at most the one entry a just-landed early convergence
    /// event stashed for a task that has not yet called
    /// `awaitConvergenceResolution` to collect it -- a growing count would
    /// mean some path is stashing a result nothing will ever read.
    var pendingConvergenceResultCountForTesting: Int { resolvedConvergence.count }

    private struct PendingConvergence {
        let generation: Int
        let kinds: Set<ConvergenceKind>
        /// The orders the plan's workspace reorders pass through before its
        /// last one, never including its final order; empty for a plan of one
        /// reorder or none. herdr confirms each reorder with its own event, so
        /// these are exactly the orders a live event can carry that the
        /// overlay has already moved past.
        let intermediateWorkspaceOrders: Set<[WorkspaceID]>
    }

    public init(
        socketPath: String,
        resnapshotInterval: Duration = .seconds(300),
        backoffSchedule: @escaping (Int) -> Duration = HerdrStore.defaultBackoff,
        overlayConvergenceTimeout: Duration = .seconds(2),
        requestTimeout: Duration = HerdrClient.defaultRequestTimeout
    ) {
        self.socketPath = socketPath
        self.resnapshotInterval = resnapshotInterval
        self.backoffSchedule = backoffSchedule
        self.overlayConvergenceTimeout = overlayConvergenceTimeout
        self.requestTimeout = requestTimeout
    }

    public func start() async {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        isStopped = true
        runLoopTask?.cancel()
        runLoopTask = nil
        if let socket = activeSubscribeSocket {
            activeSubscribeSocket = nil
            Task { await socket.close() }
        }
        if let generation = pendingConvergence?.generation {
            resolveConvergence(generation, matched: false)
        }
    }

    /// Predicts the plan's outcome into a copy of `model` (see
    /// `predictedModel`; it updates pane/tab/workspace records but not
    /// `LayoutSnapshot` geometry, so the canvas itself still waits for the
    /// real `layout.updated` event) and publishes that overlay before
    /// running the real plan. The convergence watch is armed synchronously,
    /// before the wire round trip even starts, since herdr's subscriber
    /// polls independently and a confirming event can land during the round
    /// trip rather than only after it. `renamePane` never converges (herdr's
    /// rename handler emits no event for a label-only change), so a plan
    /// whose ops produce no waitable convergence kind at all arms nothing
    /// and simply trusts the response.
    ///
    /// Failure, or a watch that times out, reverts to the pre-overlay model
    /// and asks for a fresh snapshot -- a failure can still have partially
    /// applied real changes on herdr's side, so a plain revert to the
    /// pre-plan model would hide those; the re-snapshot is what actually
    /// resyncs.
    public func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        guard !plan.ops.isEmpty else {
            return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: [], label: plan.label)))
        }
        guard let baseModel = model else {
            return .failure(OpFailure(
                failedOp: plan.ops[0], code: "no_model", message: "no session model available yet",
                executed: [], partialInverse: OpPlan(ops: [], label: plan.label)
            ))
        }

        let prediction = Self.predictedModel(applying: plan, to: baseModel)
        model = prediction.model
        overlayGeneration += 1
        let generation = overlayGeneration

        let kinds = Self.convergenceKinds(for: plan)
        if !kinds.isEmpty {
            armConvergence(kinds: kinds, generation: generation, intermediateWorkspaceOrders: prediction.intermediateWorkspaceOrders)
        }

        let engine = MutationEngine(client: HerdrClient(socketPath: socketPath, requestTimeout: requestTimeout))
        let result = await engine.execute(plan, model: baseModel)

        switch result {
        case .success:
            guard !kinds.isEmpty else { break }
            Task { [weak self] in
                guard let self else { return }
                let matched = await self.awaitConvergenceResolution(generation: generation, timeout: self.overlayConvergenceTimeout)
                guard !matched else { return }
                await self.revertAndResnapshot(fallback: baseModel, generation: generation)
            }
        case .failure:
            await revertAndResnapshot(fallback: baseModel, generation: generation)
        }
        return result
    }

    // MARK: - optimistic overlay

    private enum ConvergenceKind: Hashable, Sendable {
        case paneMoved, paneUpdated, layoutUpdated, tabMoved, workspaceMoved, tabRenamed, workspaceRenamed
        case paneFocused, tabFocused, workspaceFocused
    }

    /// Registers interest synchronously (never inside a spawned `Task`, so
    /// there is no scheduling race against the wire call that follows).
    /// Superseding an unresolved watch resolves it "not matched" first, so a
    /// second `execute` racing ahead of the first can never leave a result
    /// permanently uncollected.
    private func armConvergence(kinds: Set<ConvergenceKind>, generation: Int, intermediateWorkspaceOrders: Set<[WorkspaceID]>) {
        if let previous = pendingConvergence {
            resolveConvergence(previous.generation, matched: false)
        }
        pendingConvergence = PendingConvergence(
            generation: generation, kinds: kinds, intermediateWorkspaceOrders: intermediateWorkspaceOrders
        )
    }

    private static func isWorkspaceReorder(_ op: PrimitiveOp) -> Bool {
        switch op {
        case .moveWorkspace, .moveWorkspaceBlock: true
        default: false
        }
    }

    private static func workspaceOrder(carriedBy event: HerdrEvent) -> [WorkspaceID]? {
        switch event {
        case .workspaceMoved(let workspaces), .workspaceReordered(let workspaces): workspaces.map(\.workspaceID)
        default: nil
        }
    }

    private func resolveConvergence(_ generation: Int, matched: Bool) {
        guard pendingConvergence?.generation == generation else { return }
        pendingConvergence = nil
        if let pair = convergenceContinuation, pair.generation == generation {
            convergenceContinuation = nil
            pair.continuation.resume(returning: matched)
        } else {
            resolvedConvergence[generation] = matched
        }
    }

    /// Clears a still-pending watch WITHOUT stashing a result -- used on the
    /// failure path, where nothing ever spawned a task that will call
    /// `awaitConvergenceResolution` for this generation to collect it. Using
    /// `resolveConvergence` there instead would leave one `resolvedConvergence`
    /// entry behind per failed `execute`, forever.
    private func discardConvergence(_ generation: Int) {
        // A generation can reach here having ALREADY been stashed (armed,
        // then superseded by a later `execute` before this one's own
        // failure was discovered) -- `resolveConvergence`'s "nobody waiting"
        // branch stashes unconditionally, so clear that stash too, not only
        // the still-pending case below.
        resolvedConvergence.removeValue(forKey: generation)
        guard pendingConvergence?.generation == generation else { return }
        pendingConvergence = nil
        if let pair = convergenceContinuation, pair.generation == generation {
            convergenceContinuation = nil
            pair.continuation.resume(returning: false)
        }
    }

    /// Waits for `armConvergence(kinds:generation:)`'s watch to resolve,
    /// picking up an outcome that already landed (a matching event arrived
    /// during the round trip, or the watch was superseded) before this is
    /// even called.
    private func awaitConvergenceResolution(generation: Int, timeout: Duration) async -> Bool {
        if let already = resolvedConvergence.removeValue(forKey: generation) { return already }
        guard pendingConvergence?.generation == generation else { return true }
        return await withCheckedContinuation { continuation in
            convergenceContinuation = (generation, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                self.resolveConvergence(generation, matched: false)
            }
        }
    }

    private func revertAndResnapshot(fallback: SessionModel, generation: Int) async {
        discardConvergence(generation)
        guard !isStopped, overlayGeneration == generation else { return }
        model = fallback
        let client = HerdrClient(socketPath: socketPath, requestTimeout: requestTimeout)
        guard let line = try? await client.requestRaw("session.snapshot", [:]),
              let snapshot = try? HerdrDecoder.snapshot(fromResponseLine: line)
        else { return }
        guard !isStopped, overlayGeneration == generation else { return }
        model = SessionModel(snapshot: snapshot)
    }

    /// Every op this plan will run mapped to the live event family that
    /// confirms it landed. An op the executor cannot predict (see
    /// `predictedEvent`) still gets a convergence kind here: the prediction
    /// and the confirmation watch are independent -- skipping prediction
    /// only means the overlay never showed that particular change early, not
    /// that the store stops waiting to hear it really happened. `renamePane`
    /// is the one exception: herdr's rename handler emits no event at all
    /// for a label-only change (confirmed against source), so there is
    /// nothing to ever wait for -- a plan of rename-pane ops only, or of ops
    /// that otherwise never map to a kind, arms no watch at all.
    private static func convergenceKinds(for plan: OpPlan) -> Set<ConvergenceKind> {
        var kinds: Set<ConvergenceKind> = []
        if !plan.needsUnzoom.isEmpty { kinds.insert(.layoutUpdated) }
        for op in plan.ops {
            switch op {
            case .movePaneToTab, .movePaneToNewTab, .movePaneToNewWorkspace, .swapPanes:
                kinds.insert(.paneMoved)
                kinds.insert(.layoutUpdated)
            case .setSplitRatio, .zoom:
                kinds.insert(.layoutUpdated)
            case .moveTab:
                kinds.insert(.tabMoved)
            case .moveWorkspace, .moveWorkspaceBlock:
                kinds.insert(.workspaceMoved)
            case .renamePane:
                break
            case .renameTab:
                kinds.insert(.tabRenamed)
            case .renameWorkspace:
                kinds.insert(.workspaceRenamed)
            case .closePane, .closeTab, .closeWorkspace:
                break
            case .focusPane:
                kinds.insert(.paneFocused)
            case .focusTab:
                kinds.insert(.tabFocused)
            case .focusWorkspace:
                kinds.insert(.workspaceFocused)
            }
        }
        return kinds
    }

    private static func convergenceKind(of event: HerdrEvent) -> ConvergenceKind? {
        switch event {
        case .paneMoved: return .paneMoved
        case .paneUpdated: return .paneUpdated
        case .layoutUpdated: return .layoutUpdated
        case .tabMoved: return .tabMoved
        case .workspaceMoved, .workspaceReordered: return .workspaceMoved
        case .tabRenamed: return .tabRenamed
        case .workspaceRenamed: return .workspaceRenamed
        case .paneFocused: return .paneFocused
        case .tabFocused: return .tabFocused
        case .workspaceFocused: return .workspaceFocused
        default: return nil
        }
    }

    /// Applies `plan`'s expected outcome to a copy of `model` by synthesizing
    /// the `HerdrEvent` herdr would send for each op and running it through
    /// the same `apply(_:to:)` reducers the live stream uses -- never a
    /// bespoke prediction path. An op this cannot express honestly (a move
    /// that creates a tab/workspace, whose real id is unknowable ahead of
    /// the round trip; a swap, whose effect lives only in geometry this
    /// model does not carry) is simply skipped: the overlay shows every
    /// change it safely can and leaves the rest to converge normally when
    /// the real event arrives.
    ///
    /// A predicted `movePaneToTab` updates `model.panes`' record for the
    /// moved pane (its `tabID`/`workspaceID`), matching `Reducers.swift`'s
    /// own `.paneMoved` case exactly -- but that reducer does not touch
    /// `LayoutSnapshot.panes`/`splits` either, so neither does this
    /// prediction. The canvas, which reads layout geometry, still waits for
    /// the real `layout.updated` event that follows; only pane/tab/workspace
    /// record state (tab strips, pane lists, sidebar membership) reflects
    /// the overlay on the same frame as the call.
    ///
    /// `setSplitRatio` is the one op whose WHOLE effect lives in the layout's
    /// own geometry, so it is the one exception to that last rule: its
    /// predicted event carries a rebuilt `LayoutSnapshot` with the target
    /// split's ratio changed and every pane/split rect beneath it
    /// recomputed, so the canvas shows the real post-drag arrangement
    /// immediately rather than jumping to it once `layout.updated` lands.
    private static func predictedModel(
        applying plan: OpPlan, to model: SessionModel
    ) -> (model: SessionModel, intermediateWorkspaceOrders: Set<[WorkspaceID]>) {
        var predicted = model
        for tabID in plan.needsUnzoom {
            guard let layout = predicted.layouts[tabID], layout.zoomed else { continue }
            apply(.layoutUpdated(Self.withZoom(false, focus: nil, in: layout)), to: &predicted)
        }
        var orderAfterEachReorder: [[WorkspaceID]] = []
        for op in plan.ops {
            for event in Self.predictedEvents(for: op, model: predicted) {
                apply(event, to: &predicted)
            }
            if isWorkspaceReorder(op) {
                orderAfterEachReorder.append(predicted.workspaces.map(\.workspaceID))
            }
        }
        // The final order must always converge the watch, even when an
        // earlier step happened to pass through it.
        var intermediate = Set(orderAfterEachReorder.dropLast())
        intermediate.remove(predicted.workspaces.map(\.workspaceID))
        return (predicted, intermediate)
    }

    /// The events herdr would send for one op, in the order it would send
    /// them. Several, or none: `pane.zoom` moves focus as well as the zoom
    /// (`apply_pane_zoom` focuses the pane it names first), and an op whose
    /// outcome cannot be expressed honestly predicts nothing at all.
    private static func predictedEvents(for op: PrimitiveOp, model: SessionModel) -> [HerdrEvent] {
        switch op {
        case let .movePaneToTab(pane, tab, _, _, _):
            guard let old = model.panes[pane], let workspaceID = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key else { return [] }
            let moved = PaneRecord(
                paneID: pane, workspaceID: workspaceID, tabID: tab, focused: old.focused, agentStatus: old.agentStatus,
                revision: old.revision, terminalTitleStripped: old.terminalTitleStripped, label: old.label, cwd: old.cwd, scroll: old.scroll,
                terminalID: old.terminalID
            )
            return [.paneMoved(PaneMovedPayload(
                previousPaneID: pane, previousWorkspaceID: old.workspaceID, previousTabID: old.tabID,
                pane: moved, createdTab: nil, createdWorkspace: nil, closedTabID: nil, closedWorkspaceID: nil
            ))]

        case let .renamePane(pane, label):
            guard let old = model.panes[pane] else { return [] }
            let renamed = PaneRecord(
                paneID: old.paneID, workspaceID: old.workspaceID, tabID: old.tabID, focused: old.focused, agentStatus: old.agentStatus,
                revision: old.revision, terminalTitleStripped: old.terminalTitleStripped, label: label, cwd: old.cwd, scroll: old.scroll,
                terminalID: old.terminalID
            )
            return [.paneUpdated(renamed)]

        case let .renameTab(tab, label):
            return [.tabRenamed(tab, label)]

        case let .renameWorkspace(workspace, label):
            return [.workspaceRenamed(workspace, label)]

        case let .moveTab(tab, insertIndex):
            guard let workspaceID = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key,
                  var tabs = model.tabs[workspaceID],
                  let index = tabs.firstIndex(where: { $0.tabID == tab })
            else { return [] }
            let record = tabs.remove(at: index)
            let actual = Self.gapAdjustedResultIndex(source: index, insert: insertIndex)
            tabs.insert(record, at: min(max(actual, 0), tabs.count))
            return [.tabMoved(tab, workspaceID, tabs)]

        case let .moveWorkspace(workspace, insertIndex):
            var workspaces = model.workspaces
            guard let index = workspaces.firstIndex(where: { $0.workspaceID == workspace }) else { return [] }
            let record = workspaces.remove(at: index)
            let actual = Self.gapAdjustedResultIndex(source: index, insert: insertIndex)
            workspaces.insert(record, at: min(max(actual, 0), workspaces.count))
            return [.workspaceMoved(workspaces)]

        case let .moveWorkspaceBlock(block, before):
            guard let workspaces = WorkspaceBlockMove.apply(block: block, before: before, to: model.workspaces, id: \.workspaceID) else { return [] }
            return [.workspaceReordered(workspaces)]

        case let .focusPane(pane):
            return [.paneFocused(pane)]
        case let .focusTab(tab):
            return [.tabFocused(tab)]
        case let .focusWorkspace(workspace):
            return [.workspaceFocused(workspace)]

        case let .zoom(pane, mode):
            guard let record = model.panes[pane], let layout = model.layouts[record.tabID] else { return [] }
            let newZoomed: Bool
            switch mode {
            case .on: newZoomed = true
            case .off: newZoomed = false
            case .toggle: newZoomed = !layout.zoomed
            }
            // Both halves of what herdr does, in its own order: the focus
            // moves whatever the zoom does, so the canvas paints the held
            // pane as the focused one rather than wearing an unfocused
            // border until the echo lands.
            return [.paneFocused(pane), .layoutUpdated(Self.withZoom(newZoomed, focus: pane, in: layout))]

        case let .setSplitRatio(tab, path, ratio):
            guard let newLayout = Self.predictedLayout(forSplitRatio: ratio, atPath: path, tab: tab, model: model) else { return [] }
            return [.layoutUpdated(newLayout)]

        case .movePaneToNewTab, .movePaneToNewWorkspace, .swapPanes,
             .closePane, .closeTab, .closeWorkspace:
            return []
        }
    }

    /// Rebuilds `tab`'s own `LayoutSnapshot` for a `setSplitRatio` at `path`:
    /// the target split's `rect` never moves (it is still the same region,
    /// just divided differently), but every rect BELOW it does, recomputed
    /// with `childRegions` -- the identical cell-rounded derivation
    /// `CanvasGeometry`'s exported-tree walk uses -- so the predicted
    /// overlay matches the real `layout.updated` event exactly rather than
    /// approximating it and then having to jump. Descending to the target
    /// uses each ancestor's own EXISTING ratio; only the target split's own
    /// children use the new one.
    ///
    /// Both the target lookup and the reflow below resolve every split by
    /// its PATH (`CanvasGeometry.splitPaths`, resolved once), never by
    /// re-matching a rect fresh at each step: a ratio that rounds a child to
    /// zero cells makes that child's rect identical to its own parent's
    /// (`childRegions`, both branches derive their sizes from the SAME
    /// parent extent), and a rect lookup repeated at every level of an
    /// unbounded recursion would re-find that same split there forever --
    /// reachable with nothing more exotic than a 2-row `.down` region at
    /// ratio 0.1, which both herdr's own clamp and flock's cell-floor
    /// fallback permit. A path, resolved once, cannot re-match a shallower
    /// split by coincidence; `nodePath` strictly grows by one element every
    /// recursive call, so the walk is bounded by the tree's own depth
    /// regardless.
    ///
    /// Returns `nil` when `path` cannot be resolved against `tab`'s own
    /// split tree (no layout for the tab, or a path stale relative to it) --
    /// a mispredicted layout is worse than none, since the canvas would show
    /// something the real event then has to correct anyway.
    private static func predictedLayout(forSplitRatio ratio: Double, atPath path: [Bool], tab: TabID, model: SessionModel) -> LayoutSnapshot? {
        guard let layout = model.layouts[tab] else { return nil }
        let pathBySplitID = CanvasGeometry.splitPaths(splits: layout.splits, area: layout.area)
        // Never `Dictionary(uniqueKeysWithValues:)`: derived data, built
        // from a caller-supplied path resolution this function does not
        // control the invariants of -- a trap on unverified input is worse
        // than declining the prediction. `CanvasGeometry.splitPaths`'s own
        // structural derivation should never produce two splits at the same
        // path, but "should never" is exactly the wrong thing to trust with
        // a fatal initializer; a genuine collision here declines instead.
        var splitByPath: [[Bool]: SplitInfo] = [:]
        for split in layout.splits {
            guard let splitPath = pathBySplitID[split.id] else { continue }
            guard splitByPath[splitPath] == nil else { return nil }
            splitByPath[splitPath] = split
        }
        guard let target = splitByPath[path] else { return nil }
        let targetID = target.id

        var splitRects: [String: CellRect] = [:]
        var paneRects: [PaneID: CellRect] = [:]
        // `originalRect` identifies which pane occupies a LEAF branch (via
        // the layout AS IT STOOD); `newRect` is where that same entity lands
        // once the target's own ratio changes. The two only ever diverge
        // below the target -- everywhere else they stay equal, which is
        // exactly why an ancestor or an out-of-subtree sibling's rect never
        // moves. Splits themselves are identified by `nodePath` against
        // `splitByPath`, never by rect.
        func reflow(nodePath: [Bool], originalRect: CellRect, newRect: CellRect) {
            if let split = splitByPath[nodePath] {
                splitRects[split.id] = newRect
                let effectiveRatio = split.id == targetID ? ratio : split.ratio
                let (originalFirst, originalSecond) = childRegions(of: originalRect, direction: split.direction, ratio: split.ratio)
                let (newFirst, newSecond) = childRegions(of: newRect, direction: split.direction, ratio: effectiveRatio)
                reflow(nodePath: nodePath + [false], originalRect: originalFirst, newRect: newFirst)
                reflow(nodePath: nodePath + [true], originalRect: originalSecond, newRect: newSecond)
            } else if let pane = layout.panes.first(where: { $0.rect == originalRect }) {
                paneRects[pane.paneID] = newRect
            }
        }
        reflow(nodePath: path, originalRect: target.rect, newRect: target.rect)

        let newSplits = layout.splits.map { split -> SplitInfo in
            guard let newRect = splitRects[split.id] else { return split }
            let newRatio = split.id == targetID ? ratio : split.ratio
            return SplitInfo(id: split.id, direction: split.direction, ratio: newRatio, rect: newRect)
        }
        let newPanes = layout.panes.map { pane -> PaneRect in
            guard let newRect = paneRects[pane.paneID] else { return pane }
            return PaneRect(paneID: pane.paneID, focused: pane.focused, rect: newRect)
        }
        return LayoutSnapshot(
            workspaceID: layout.workspaceID, tabID: layout.tabID, zoomed: layout.zoomed, area: layout.area,
            focusedPaneID: layout.focusedPaneID, panes: newPanes, splits: newSplits
        )
    }

    /// Duplicated from `CanvasGeometry`'s and `MutationEngine`'s own copies
    /// rather than shared -- the same three-line, dependency-free formula,
    /// not a seam worth coupling three unrelated files over.
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

    /// herdr's `tab.move`/`workspace.move` treat `insertIndex` as a position
    /// in the list with the moved item already removed: the actual
    /// resulting index is `insert - 1` when the item's prior index was
    /// before `insert`, else `insert` outright (source: herdr's own
    /// `workspace.rs`/`actions.rs`). Duplicated from `MutationEngine`'s own
    /// copy rather than shared -- same one-line-formula, different module
    /// boundary.
    private static func gapAdjustedResultIndex(source: Int, insert: Int) -> Int {
        source < insert ? insert - 1 : insert
    }

    /// `focus` moves the TAB's own focused pane, which herdr's `pane.zoom`
    /// always does: `apply_pane_zoom` (`herdr/src/app/actions.rs`) focuses the
    /// named pane before it reads `tab.zoomed` at all, for every mode and even
    /// for a no-op. Predicting the zoom without it would leave the canvas
    /// holding open whichever pane was focused BEFORE a zoom aimed from an
    /// unfocused pane's own menu, until herdr's echo swapped it.
    private static func withZoom(_ zoomed: Bool, focus: PaneID?, in layout: LayoutSnapshot) -> LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: layout.workspaceID, tabID: layout.tabID, zoomed: zoomed, area: layout.area,
            focusedPaneID: focus ?? layout.focusedPaneID, panes: layout.panes, splits: layout.splits
        )
    }

    public nonisolated static func defaultBackoff(attempt: Int) -> Duration {
        guard attempt > 1 else { return .milliseconds(500) }
        let shift = min(attempt - 1, 30)
        return .milliseconds(min(15_000, 500 << shift))
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await bootstrapAndRun()
            } catch is CancellationError {
                return
            } catch let error as HerdrClientError {
                if case .protocolTooOld = error {
                    connection = .unsupported(error)
                    return
                }
                await waitBeforeRetry()
            } catch {
                await waitBeforeRetry()
            }
        }
    }

    private func waitBeforeRetry() async {
        guard !Task.isCancelled else { return }
        reconnectAttempt += 1
        connection = .reconnecting(attempt: reconnectAttempt)
        try? await Task.sleep(for: backoffSchedule(reconnectAttempt))
    }

    private func bootstrapAndRun() async throws {
        let socket = try await LineSocket(path: socketPath)
        activeSubscribeSocket = socket
        let relay = EventRelay()
        var readingTask: Task<Void, Never>?
        do {
            try await socket.send(line: try Self.subscribeRequestLine())

            try Self.validateAck(try await Self.awaitAck(on: socket, within: requestTimeout))

            let socketLines = socket.lines
            let task = Task {
                do {
                    for try await line in socketLines {
                        await relay.receive(line)
                    }
                } catch {
                    // Stream ended with a transport error: the live consumer
                    // below surfaces this identically to a clean EOF.
                }
                await relay.finish()
            }
            readingTask = task

            let client = HerdrClient(socketPath: socketPath, requestTimeout: requestTimeout)
            try await client.verifyProtocol()
            let snapshotLine = try await client.requestRaw("session.snapshot", [:])
            var newModel = SessionModel(snapshot: try HerdrDecoder.snapshot(fromResponseLine: snapshotLine))

            let (buffered, liveStream) = await relay.drainAndSwitchToLive()
            for line in buffered {
                if let event = try? HerdrDecoder.event(fromLine: line) {
                    apply(event, to: &newModel)
                }
            }
            model = newModel
            connection = .live
            reconnectAttempt = 0

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await line in liveStream {
                        guard let self, let event = try? HerdrDecoder.event(fromLine: line) else { continue }
                        await self.applyLiveEvent(event)
                    }
                    throw HerdrClientError.transport("subscription stream ended")
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.resnapshotLoop(client: client)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            readingTask?.cancel()
            await socket.close()
            if activeSubscribeSocket === socket { activeSubscribeSocket = nil }
            await readingTask?.value
            throw error
        }
    }

    /// The ack is a request in everything but which connection it rides:
    /// herdr answers it at once, and it is the STREAM after it that may sit
    /// quiet for hours. Unbounded, a server that accepts the subscribe
    /// connection and then never acks leaves the store at `.connecting` with
    /// nothing to drive a reconnect; bounded, it fails like any other request
    /// and the run loop's own backoff picks it up.
    private static func awaitAck(on socket: LineSocket, within timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for try await line in socket.lines {
                    return line
                }
                throw HerdrClientError.transport("subscription connection closed before ack")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HerdrClientError.timedOut(method: "events.subscribe")
            }
            defer { group.cancelAll() }
            guard let line = try await group.next() else {
                throw HerdrClientError.transport("subscription connection closed before ack")
            }
            return line
        }
    }

    /// The pane-scoped scroll feed's entry point: one `pane.scroll_changed`
    /// subscription per attached pane (`PaneScrollSubscriber`) lands here,
    /// off the blanket subscription, and reduces like any live event.
    public func applyScrollChanged(pane: PaneID, scroll: ScrollInfo) {
        applyLiveEvent(.paneScrollChanged(pane, scroll))
    }

    /// The pane-scoped agent-status feed's entry point: one
    /// `pane.agent_status_changed` subscription per pane herdr reports
    /// (`PaneAgentStatusSubscriber`) lands here, off the blanket
    /// subscription, and reduces like any live event.
    public func applyAgentStatusChanged(pane: PaneID, status: AgentStatus) {
        applyLiveEvent(.paneAgentStatusChanged(pane, status))
    }

    private func applyLiveEvent(_ event: HerdrEvent) {
        guard var current = model else { return }
        // Dropped, never applied: one of the plan's own steps would flash the
        // rail back through an order the overlay has already passed. Nothing
        // is lost, since the plan's next reorder event carries the full
        // workspace list again and a plan that fails resnapshots. Any other
        // order, from another client included, applies at once.
        if let order = Self.workspaceOrder(carriedBy: event), pendingConvergence?.intermediateWorkspaceOrders.contains(order) == true {
            return
        }
        apply(event, to: &current)
        model = current
        if let pending = pendingConvergence, let kind = Self.convergenceKind(of: event), pending.kinds.contains(kind) {
            resolveConvergence(pending.generation, matched: true)
        }
    }

    private func resnapshotLoop(client: HerdrClient) async throws {
        while true {
            try await Task.sleep(for: resnapshotInterval)
            let line = try await client.requestRaw("session.snapshot", [:])
            model = SessionModel(snapshot: try HerdrDecoder.snapshot(fromResponseLine: line))
        }
    }

    private static let subscriptionTypes: [String] = [
        "layout.updated",
        "pane.created", "pane.updated", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
        "tab.created", "tab.closed", "tab.renamed", "tab.moved", "tab.focused",
        "workspace.created", "workspace.closed", "workspace.renamed",
        "workspace.moved", "workspace.reordered", "workspace.focused",
    ]

    private static func subscribeRequestLine() throws -> Data {
        struct Subscription: Encodable { let type: String }
        struct Params: Encodable { let subscriptions: [Subscription] }
        struct Envelope: Encodable { let id: String; let method: String; let params: Params }
        let params = Params(subscriptions: subscriptionTypes.map(Subscription.init))
        do {
            return try JSONEncoder().encode(Envelope(id: "flock:subscribe", method: "events.subscribe", params: params))
        } catch {
            throw HerdrClientError.transport("encode failed: \(error)")
        }
    }

    private static func validateAck(_ line: Data) throws {
        struct ErrorPeek: Decodable {
            struct Payload: Decodable { let code: String; let message: String }
            let error: Payload?
        }
        guard let peek = try? JSONDecoder().decode(ErrorPeek.self, from: line) else { return }
        if let error = peek.error {
            throw HerdrClientError.server(code: error.code, message: error.message)
        }
    }
}

/// Bridges connection A's push feed across the concurrent snapshot request:
/// buffers until told to switch, then forwards live. An actor rather than a
/// lock because the writer (the reading task) and the reader (the bootstrap
/// flow, on the main actor) run on different executors.
private actor EventRelay {
    private var buffered: [Data] = []
    private var liveContinuation: AsyncStream<Data>.Continuation?
    private var isFinished = false

    func receive(_ line: Data) {
        if let liveContinuation {
            liveContinuation.yield(line)
        } else {
            buffered.append(line)
        }
    }

    /// A stream already finished when connection A died during the snapshot:
    /// the end of this stream is the ONLY thing that reports that death to the
    /// bootstrap's task group, and a continuation created after the reading
    /// task ended would never yield and never finish, leaving the store live
    /// on a subscription nothing can revive until the re-snapshot backstop
    /// comes around minutes later.
    func drainAndSwitchToLive() -> (buffered: [Data], stream: AsyncStream<Data>) {
        let drained = buffered
        buffered = []
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        if isFinished {
            continuation.finish()
        } else {
            liveContinuation = continuation
        }
        return (drained, stream)
    }

    func finish() {
        isFinished = true
        liveContinuation?.finish()
    }
}
