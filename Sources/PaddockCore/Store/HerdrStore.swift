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
    private let overlayConvergenceTimeout: Duration

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
    }

    public init(
        socketPath: String,
        resnapshotInterval: Duration = .seconds(300),
        backoffSchedule: @escaping (Int) -> Duration = HerdrStore.defaultBackoff,
        overlayConvergenceTimeout: Duration = .seconds(2)
    ) {
        self.socketPath = socketPath
        self.resnapshotInterval = resnapshotInterval
        self.backoffSchedule = backoffSchedule
        self.overlayConvergenceTimeout = overlayConvergenceTimeout
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

        model = Self.predictedModel(applying: plan, to: baseModel)
        overlayGeneration += 1
        let generation = overlayGeneration

        let kinds = Self.convergenceKinds(for: plan)
        if !kinds.isEmpty {
            armConvergence(kinds: kinds, generation: generation)
        }

        let engine = MutationEngine(client: HerdrClient(socketPath: socketPath))
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
    private func armConvergence(kinds: Set<ConvergenceKind>, generation: Int) {
        if let previous = pendingConvergence {
            resolveConvergence(previous.generation, matched: false)
        }
        pendingConvergence = PendingConvergence(generation: generation, kinds: kinds)
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
        let client = HerdrClient(socketPath: socketPath)
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
            case .moveWorkspace:
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
    private static func predictedModel(applying plan: OpPlan, to model: SessionModel) -> SessionModel {
        var predicted = model
        for tabID in plan.needsUnzoom {
            guard let layout = predicted.layouts[tabID], layout.zoomed else { continue }
            apply(.layoutUpdated(Self.withZoomed(false, layout)), to: &predicted)
        }
        for op in plan.ops {
            guard let event = Self.predictedEvent(for: op, model: predicted) else { continue }
            apply(event, to: &predicted)
        }
        return predicted
    }

    private static func predictedEvent(for op: PrimitiveOp, model: SessionModel) -> HerdrEvent? {
        switch op {
        case let .movePaneToTab(pane, tab, _, _, _):
            guard let old = model.panes[pane], let workspaceID = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key else { return nil }
            let moved = PaneRecord(
                paneID: pane, workspaceID: workspaceID, tabID: tab, focused: old.focused, agentStatus: old.agentStatus,
                revision: old.revision, terminalTitleStripped: old.terminalTitleStripped, label: old.label, cwd: old.cwd, scroll: old.scroll
            )
            return .paneMoved(PaneMovedPayload(
                previousPaneID: pane, previousWorkspaceID: old.workspaceID, previousTabID: old.tabID,
                pane: moved, createdTab: nil, createdWorkspace: nil, closedTabID: nil, closedWorkspaceID: nil
            ))

        case let .renamePane(pane, label):
            guard let old = model.panes[pane] else { return nil }
            let renamed = PaneRecord(
                paneID: old.paneID, workspaceID: old.workspaceID, tabID: old.tabID, focused: old.focused, agentStatus: old.agentStatus,
                revision: old.revision, terminalTitleStripped: old.terminalTitleStripped, label: label, cwd: old.cwd, scroll: old.scroll
            )
            return .paneUpdated(renamed)

        case let .renameTab(tab, label):
            return .tabRenamed(tab, label)

        case let .renameWorkspace(workspace, label):
            return .workspaceRenamed(workspace, label)

        case let .moveTab(tab, insertIndex):
            guard let workspaceID = model.tabs.first(where: { $0.value.contains { $0.tabID == tab } })?.key,
                  var tabs = model.tabs[workspaceID],
                  let index = tabs.firstIndex(where: { $0.tabID == tab })
            else { return nil }
            let record = tabs.remove(at: index)
            let actual = Self.gapAdjustedResultIndex(source: index, insert: insertIndex)
            tabs.insert(record, at: min(max(actual, 0), tabs.count))
            return .tabMoved(tab, workspaceID, tabs)

        case let .moveWorkspace(workspace, insertIndex):
            var workspaces = model.workspaces
            guard let index = workspaces.firstIndex(where: { $0.workspaceID == workspace }) else { return nil }
            let record = workspaces.remove(at: index)
            let actual = Self.gapAdjustedResultIndex(source: index, insert: insertIndex)
            workspaces.insert(record, at: min(max(actual, 0), workspaces.count))
            return .workspaceMoved(workspaces)

        case let .focusPane(pane):
            return .paneFocused(pane)
        case let .focusTab(tab):
            return .tabFocused(tab)
        case let .focusWorkspace(workspace):
            return .workspaceFocused(workspace)

        case let .zoom(pane, mode):
            guard let record = model.panes[pane], let layout = model.layouts[record.tabID] else { return nil }
            let newZoomed: Bool
            switch mode {
            case .on: newZoomed = true
            case .off: newZoomed = false
            case .toggle: newZoomed = !layout.zoomed
            }
            return .layoutUpdated(Self.withZoomed(newZoomed, layout))

        case let .setSplitRatio(tab, path, ratio):
            guard let newLayout = Self.predictedLayout(forSplitRatio: ratio, atPath: path, tab: tab, model: model) else { return nil }
            return .layoutUpdated(newLayout)

        case .movePaneToNewTab, .movePaneToNewWorkspace, .swapPanes,
             .closePane, .closeTab, .closeWorkspace:
            return nil
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
    /// children use the new one. Returns `nil` when `path` cannot be
    /// resolved against `tab`'s own split tree (no layout for the tab, or a
    /// path stale relative to it) -- a mispredicted layout is worse than
    /// none, since the canvas would show something the real event then has
    /// to correct anyway.
    private static func predictedLayout(forSplitRatio ratio: Double, atPath path: [Bool], tab: TabID, model: SessionModel) -> LayoutSnapshot? {
        guard let layout = model.layouts[tab] else { return nil }
        guard var current = layout.splits.first(where: { $0.rect == layout.area })
            ?? layout.splits.max(by: { cellArea($0.rect) < cellArea($1.rect) })
        else { return nil }
        for branch in path {
            let (first, second) = childRegions(of: current.rect, direction: current.direction, ratio: current.ratio)
            let target = branch ? second : first
            guard let next = layout.splits.first(where: { $0.rect == target }) else { return nil }
            current = next
        }
        let targetID = current.id

        var splitRects: [String: CellRect] = [:]
        var paneRects: [PaneID: CellRect] = [:]
        // `original` identifies which split/pane occupies this branch (via
        // the layout AS IT STOOD, matching `CanvasGeometry.dividerHandles`'s
        // own containment lookup); `new` is where that same entity lands
        // once the target's own ratio changes. The two only ever diverge
        // below the target -- everywhere else they stay equal, which is
        // exactly why an ancestor or an out-of-subtree sibling's rect never
        // moves.
        func reflow(original: CellRect, new: CellRect) {
            if let split = layout.splits.first(where: { $0.rect == original }) {
                splitRects[split.id] = new
                let effectiveRatio = split.id == targetID ? ratio : split.ratio
                let (originalFirst, originalSecond) = childRegions(of: original, direction: split.direction, ratio: split.ratio)
                let (newFirst, newSecond) = childRegions(of: new, direction: split.direction, ratio: effectiveRatio)
                reflow(original: originalFirst, new: newFirst)
                reflow(original: originalSecond, new: newSecond)
            } else if let pane = layout.panes.first(where: { $0.rect == original }) {
                paneRects[pane.paneID] = new
            }
        }
        reflow(original: current.rect, new: current.rect)

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

    private static func cellArea(_ rect: CellRect) -> Int { rect.width * rect.height }

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

    private static func withZoomed(_ zoomed: Bool, _ layout: LayoutSnapshot) -> LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: layout.workspaceID, tabID: layout.tabID, zoomed: zoomed, area: layout.area,
            focusedPaneID: layout.focusedPaneID, panes: layout.panes, splits: layout.splits
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

            var ackLine: Data?
            for try await line in socket.lines {
                ackLine = line
                break
            }
            guard let ackLine else {
                throw HerdrClientError.transport("subscription connection closed before ack")
            }
            try Self.validateAck(ackLine)

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

            let client = HerdrClient(socketPath: socketPath)
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

    /// The pane-scoped scroll feed's entry point: one `pane.scroll_changed`
    /// subscription per attached pane (`PaneScrollSubscriber`) lands here,
    /// off the blanket subscription, and reduces like any live event.
    public func applyScrollChanged(pane: PaneID, scroll: ScrollInfo) {
        applyLiveEvent(.paneScrollChanged(pane, scroll))
    }

    private func applyLiveEvent(_ event: HerdrEvent) {
        guard var current = model else { return }
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
            return try JSONEncoder().encode(Envelope(id: "paddock:subscribe", method: "events.subscribe", params: params))
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

    func receive(_ line: Data) {
        if let liveContinuation {
            liveContinuation.yield(line)
        } else {
            buffered.append(line)
        }
    }

    func drainAndSwitchToLive() -> (buffered: [Data], stream: AsyncStream<Data>) {
        let drained = buffered
        buffered = []
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        liveContinuation = continuation
        return (drained, stream)
    }

    func finish() {
        liveContinuation?.finish()
    }
}
