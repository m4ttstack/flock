import Foundation
import Observation

/// Ties a machine session's store to its tunnel: the store reconnects the
/// moment the forward comes up instead of waiting out a backoff begun before
/// the forward's socket existed, and `graceActive` says the store has not yet
/// been live since then, so a failing attempt is not yet "herdr isn't running".
@MainActor
@Observable
public final class MachineConnectionWatch {
    public private(set) var graceActive = false

    @ObservationIgnored private let tunnel: MachineTunnel
    @ObservationIgnored private let store: HerdrStore
    @ObservationIgnored private let grace: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var tunnelUp = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var stopped = false

    public init(
        tunnel: MachineTunnel, store: HerdrStore, grace: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.tunnel = tunnel
        self.store = store
        self.grace = grace
        self.sleep = sleep
    }

    public func start() {
        observe()
    }

    public func stop() {
        stopped = true
        endGrace()
    }

    private func observe() {
        guard !stopped else { return }
        let (tunnelState, storeState) = withObservationTracking {
            (tunnel.state, store.connection)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        handle(tunnel: tunnelState, store: storeState)
    }

    func handle(tunnel tunnelState: MachineTunnelState, store storeState: ConnectionState) {
        let wasUp = tunnelUp
        tunnelUp = tunnelState == .up
        if tunnelUp, !wasUp {
            beginGrace()
            store.reconnectNow()
        } else if !tunnelUp {
            endGrace()
        }
        if storeState == .live { endGrace() }
    }

    private func beginGrace() {
        timer?.cancel()
        graceActive = true
        let sleep = sleep
        let duration = grace
        timer = Task { [weak self] in
            try? await sleep(duration)
            guard !Task.isCancelled else { return }
            self?.graceActive = false
        }
    }

    private func endGrace() {
        timer?.cancel()
        timer = nil
        graceActive = false
    }
}
