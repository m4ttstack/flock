import Foundation
import Observation

public enum MachineTunnelState: Equatable, Sendable {
    case connecting
    case up
    case unreachable(reason: String)
    case noServer
    case stopped
}

/// One running ssh forward.
public protocol MachineTunnelChild: AnyObject {
    /// Yields ssh's last stderr line once, when the process exits.
    var exited: AsyncStream<String> { get }
    func terminate()
}

/// Keeps one machine's ssh forward alive: resolve the remote socket, spawn
/// ssh, wait for the local socket to answer, and restart with backoff
/// whenever ssh exits or the remote cannot be reached.
@MainActor
@Observable
public final class MachineTunnel {
    public private(set) var state: MachineTunnelState = .stopped

    @ObservationIgnored private let machine: HerdrMachine
    @ObservationIgnored private let paths: MachineTunnelPaths
    @ObservationIgnored private let resolve: @MainActor (HerdrMachine) async throws -> String
    @ObservationIgnored private let launch: @MainActor ([String]) throws -> MachineTunnelChild
    @ObservationIgnored private let probe: @MainActor (String) async -> Bool
    @ObservationIgnored private let prepareDirectory: @MainActor (String) throws -> Void
    @ObservationIgnored private let removeDirectory: @MainActor (String) -> Void
    @ObservationIgnored private let backoff: @MainActor (Int) -> Duration
    @ObservationIgnored private let probeInterval: Duration
    @ObservationIgnored private let connectTimeout: Duration

    @ObservationIgnored private var supervision: Task<Void, Never>?
    @ObservationIgnored private var child: MachineTunnelChild?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var attempt = 1
    @ObservationIgnored private var remoteSocket: String?
    @ObservationIgnored private var remoteSocketAnswered = false
    @ObservationIgnored private var mayReResolve = true

    public init(
        machine: HerdrMachine,
        paths: MachineTunnelPaths,
        resolve: @escaping @MainActor (HerdrMachine) async throws -> String,
        launch: @escaping @MainActor ([String]) throws -> MachineTunnelChild,
        probe: @escaping @MainActor (String) async -> Bool,
        prepareDirectory: @escaping @MainActor (String) throws -> Void,
        removeDirectory: @escaping @MainActor (String) -> Void,
        backoff: @escaping @MainActor (Int) -> Duration = MachineTunnel.defaultBackoff,
        probeInterval: Duration = .milliseconds(100),
        connectTimeout: Duration = .seconds(10)
    ) {
        self.machine = machine
        self.paths = paths
        self.resolve = resolve
        self.launch = launch
        self.probe = probe
        self.prepareDirectory = prepareDirectory
        self.removeDirectory = removeDirectory
        self.backoff = backoff
        self.probeInterval = probeInterval
        self.connectTimeout = connectTimeout
    }

    nonisolated public static func defaultBackoff(_ attempt: Int) -> Duration {
        .seconds([1, 2, 4, 8, 15][min(max(attempt, 1), 5) - 1])
    }

    public func start() {
        guard supervision == nil, !stopped else { return }
        state = .connecting
        supervision = Task { await self.supervise() }
    }

    /// Final: a stopped tunnel never restarts. Does not wait for an in-flight
    /// resolve, which may be an ssh that has not timed out yet.
    public func stop() async {
        stopNow()
    }

    /// `stop()` for app termination, which cannot await.
    public func stopNow() {
        stopped = true
        supervision?.cancel()
        supervision = nil
        child?.terminate()
        child = nil
        removeDirectory(paths.directory)
        state = .stopped
    }

    private enum ConnectEvent: Sendable {
        case answered
        case timedOut
        case exited(String)
        case cancelled
    }

    private func supervise() async {
        while !stopped {
            await connectOnce()
            guard !stopped else { return }
            let delay = backoff(attempt)
            attempt += 1
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    /// Returns after a failure, with `state` saying why. A retry leaves that
    /// state showing until it reaches `.up`.
    private func connectOnce() async {
        let socket: String
        if let cached = remoteSocket {
            socket = cached
        } else {
            do {
                socket = try await resolve(machine)
            } catch MachineResolveError.noServer {
                if !stopped { state = .noServer }
                return
            } catch {
                if !stopped { state = .unreachable(reason: describe(error)) }
                return
            }
            guard !stopped else { return }
            remoteSocket = socket
            remoteSocketAnswered = false
        }

        let launched: MachineTunnelChild
        do {
            try prepareDirectory(paths.directory)
            launched = try launch(MachineSSH.forwardArguments(target: machine.target, paths: paths, remoteAPISocket: socket))
        } catch {
            state = .unreachable(reason: describe(error))
            return
        }
        child = launched

        let reason = await watch(launched)
        guard !stopped, let reason else { return }
        if child === launched { child = nil }
        state = .unreachable(reason: reason)
        if !remoteSocketAnswered, mayReResolve {
            mayReResolve = false
            remoteSocket = nil
        }
    }

    /// The exit reason, or nil when cancelled.
    private func watch(_ launched: MachineTunnelChild) async -> String? {
        let exits = launched.exited
        let apiSocket = paths.apiSocket
        let connectTimeout = connectTimeout
        var answered = false
        return await withTaskGroup(of: ConnectEvent.self) { group in
            group.addTask {
                for await line in exits {
                    return .exited(line)
                }
                return Task.isCancelled ? .cancelled : .exited("")
            }
            group.addTask {
                await self.pollProbe(apiSocket)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: connectTimeout)
                } catch {
                    return .cancelled
                }
                return .timedOut
            }
            while let event = await group.next() {
                switch event {
                case .answered:
                    guard !stopped else { continue }
                    answered = true
                    remoteSocketAnswered = true
                    mayReResolve = true
                    attempt = 1
                    state = .up
                case .timedOut:
                    guard !answered else { continue }
                    launched.terminate()
                    group.cancelAll()
                    return "Timed out connecting."
                case .exited(let line):
                    group.cancelAll()
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "ssh exited." : trimmed
                case .cancelled:
                    continue
                }
            }
            return nil
        }
    }

    private func pollProbe(_ apiSocket: String) async -> ConnectEvent {
        while true {
            guard let answer = await probeOnce(apiSocket) else { return .cancelled }
            if answer { return .answered }
            do {
                try await Task.sleep(for: probeInterval)
            } catch {
                return .cancelled
            }
        }
    }

    /// nil when cancelled. The probe runs outside the task group because the
    /// group cannot finish until every child returns, and a hung probe must
    /// not hold up the timeout or an exit.
    private func probeOnce(_ apiSocket: String) async -> Bool? {
        let (answers, continuation) = AsyncStream<Bool>.makeStream()
        let probing = Task {
            continuation.yield(await self.probe(apiSocket))
            continuation.finish()
        }
        for await answer in answers {
            return answer
        }
        probing.cancel()
        return nil
    }

    private func describe(_ error: Error) -> String {
        if case MachineResolveError.failed(let message) = error { return message }
        if case MachineResolveError.unknownSession = error {
            return "herdr has no session named \(machine.session) on \(machine.label)."
        }
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return String(describing: error)
    }
}
