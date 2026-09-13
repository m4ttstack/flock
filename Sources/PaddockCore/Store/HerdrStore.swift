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
    private var convergenceWaiter: ConvergenceWaiter?

    private struct ConvergenceWaiter {
        let generation: Int
        let kinds: Set<ConvergenceKind>
        let continuation: CheckedContinuation<Bool, Never>
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
        runLoopTask?.cancel()
        runLoopTask = nil
        if let socket = activeSubscribeSocket {
            activeSubscribeSocket = nil
            Task { await socket.close() }
        }
        if let waiter = convergenceWaiter {
            convergenceWaiter = nil
            waiter.continuation.resume(returning: false)
        }
    }

    /// Predicts the plan's outcome into a copy of `model`, publishes that
    /// overlay immediately (before the wire round trip even starts, so the
    /// UI moves on the same frame as the call), then runs the real plan.
    /// A successful run arms a watch that waits up to
    /// `overlayConvergenceTimeout` for a live event confirming the predicted
    /// change; a failure, or a watch that times out, reverts to the
    /// pre-overlay model and asks for a fresh snapshot rather than trust a
    /// guess that never got confirmed.
    public func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        guard !plan.ops.isEmpty else {
            return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: [], label: plan.label)))
        }
        guard let baseModel = model else {
            return .failure(OpFailure(failedOp: plan.ops[0], code: "no_model", message: "no session model available yet", executed: []))
        }

        model = Self.predictedModel(applying: plan, to: baseModel)
        overlayGeneration += 1
        let generation = overlayGeneration

        let engine = MutationEngine(client: HerdrClient(socketPath: socketPath))
        let result = await engine.execute(plan, model: baseModel)

        switch result {
        case .success:
            armConvergenceWatch(expecting: Self.convergenceKinds(for: plan), fallbackModel: baseModel, generation: generation)
        case .failure:
            revertOverlay(to: baseModel, generation: generation)
        }
        return result
    }

    // MARK: - optimistic overlay

    private enum ConvergenceKind: Hashable, Sendable {
        case paneMoved, paneUpdated, layoutUpdated, tabMoved, workspaceMoved, tabRenamed, workspaceRenamed
        case paneFocused, tabFocused, workspaceFocused
    }

    private func armConvergenceWatch(expecting kinds: Set<ConvergenceKind>, fallbackModel: SessionModel, generation: Int) {
        let timeout = overlayConvergenceTimeout
        Task { [weak self] in
            guard let self else { return }
            let matched = await self.waitForConvergence(expecting: kinds, generation: generation, timeout: timeout)
            guard !matched else { return }
            self.revertOverlay(to: fallbackModel, generation: generation)
            await self.requestResnapshot(generation: generation)
        }
    }

    /// Resolves as soon as a live event of one of `kinds` arrives (via
    /// `applyLiveEvent` below) or after `timeout`, whichever comes first.
    /// Installing a new waiter always resolves any waiter it displaces as
    /// "not matched" first, so a second `execute` racing ahead of the first
    /// can never leave a continuation permanently unresumed.
    private func waitForConvergence(expecting kinds: Set<ConvergenceKind>, generation: Int, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = ConvergenceWaiter(generation: generation, kinds: kinds, continuation: continuation)
            installConvergenceWaiter(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                self.timeoutConvergenceWaiter(generation: generation)
            }
        }
    }

    private func installConvergenceWaiter(_ waiter: ConvergenceWaiter) {
        if let previous = convergenceWaiter {
            previous.continuation.resume(returning: false)
        }
        convergenceWaiter = waiter
    }

    private func timeoutConvergenceWaiter(generation: Int) {
        guard let waiter = convergenceWaiter, waiter.generation == generation else { return }
        convergenceWaiter = nil
        waiter.continuation.resume(returning: false)
    }

    private func revertOverlay(to fallbackModel: SessionModel, generation: Int) {
        guard overlayGeneration == generation else { return }
        model = fallbackModel
    }

    private func requestResnapshot(generation: Int) async {
        guard overlayGeneration == generation else { return }
        let client = HerdrClient(socketPath: socketPath)
        guard let line = try? await client.requestRaw("session.snapshot", [:]),
              let snapshot = try? HerdrDecoder.snapshot(fromResponseLine: line)
        else { return }
        guard overlayGeneration == generation else { return }
        model = SessionModel(snapshot: snapshot)
    }

    /// Every op this plan will run mapped to the live event family that
    /// confirms it landed. An op the executor cannot predict (see
    /// `predictedEvent`) still gets a convergence kind here: the prediction
    /// and the confirmation watch are independent -- skipping prediction
    /// only means the overlay never showed that particular change early, not
    /// that the store stops waiting to hear it really happened.
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
                kinds.insert(.paneUpdated)
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
    /// the round trip; a swap or split-ratio change, whose effect lives only
    /// in geometry this model does not carry) is simply skipped: the overlay
    /// shows every change it safely can and leaves the rest to converge
    /// normally when the real event arrives.
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
            tabs.insert(record, at: min(max(insertIndex, 0), tabs.count))
            return .tabMoved(tab, workspaceID, tabs)

        case let .moveWorkspace(workspace, insertIndex):
            var workspaces = model.workspaces
            guard let index = workspaces.firstIndex(where: { $0.workspaceID == workspace }) else { return nil }
            let record = workspaces.remove(at: index)
            workspaces.insert(record, at: min(max(insertIndex, 0), workspaces.count))
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

        case .movePaneToNewTab, .movePaneToNewWorkspace, .swapPanes, .setSplitRatio,
             .closePane, .closeTab, .closeWorkspace:
            return nil
        }
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

    private func applyLiveEvent(_ event: HerdrEvent) {
        guard var current = model else { return }
        apply(event, to: &current)
        model = current
        if let waiter = convergenceWaiter, let kind = Self.convergenceKind(of: event), waiter.kinds.contains(kind) {
            convergenceWaiter = nil
            waiter.continuation.resume(returning: true)
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
