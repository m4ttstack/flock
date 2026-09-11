import Foundation
import Observation

public struct OpPlan: Sendable {
    public init() {}
}

public struct ExecutedPlan: Sendable {
    public init() {}
}

public struct OpFailure: Error, Sendable {
    public init() {}
}

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

    private var runLoopTask: Task<Void, Never>?
    private var activeSubscribeSocket: LineSocket?
    private var reconnectAttempt = 0

    public init(
        socketPath: String,
        resnapshotInterval: Duration = .seconds(300),
        backoffSchedule: @escaping (Int) -> Duration = HerdrStore.defaultBackoff
    ) {
        self.socketPath = socketPath
        self.resnapshotInterval = resnapshotInterval
        self.backoffSchedule = backoffSchedule
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
    }

    public func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        .failure(OpFailure())
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
