import Foundation

/// The per-pane agent-status feed `SessionViewModel` arms for every pane
/// herdr reports. A fake stands in for it in `SessionViewModelTests`.
@MainActor
public protocol PaneAgentStatusSubscribing: AnyObject {
    func subscribe(pane: PaneID)
    func unsubscribe(pane: PaneID)
}

/// One `events.subscribe` connection per pane, carrying exactly one
/// `pane.agent_status_changed` subscription for that pane id, plus a
/// `pane.get` probe of its own once the subscription is up.
///
/// The blanket subscription cannot carry this: herdr's
/// `Subscription::PaneAgentStatusChanged` requires a `pane_id` and probes
/// that pane when the subscription is created, so there is no session-wide
/// form of it. Every pane is armed, not just the visible ones -- the rail dot
/// and the attention toasts exist precisely to report the pane nobody is
/// looking at, and a feed scoped to the visible set would answer only for the
/// panes that need no reporting.
///
/// A connection that drops (herdr restarting, the pane closing) is retried
/// after a pause until `unsubscribe`; a subscribe the server refuses (an
/// error ack) ends the feed for that pane outright, since retrying a pane
/// herdr no longer knows would never succeed.
@MainActor
public final class HerdrPaneAgentStatusSubscriber: PaneAgentStatusSubscribing {
    private let socketPath: String
    private let onChange: @MainActor (PaneID, AgentStatus) -> Void
    private let retryDelay: Duration
    private let probeTimeout: Duration
    private var feeds: [PaneID: Task<Void, Never>] = [:]
    /// Which arming a pane's slot currently holds, so a feed that ends can
    /// clear its own slot without ever clearing a newer one that a
    /// re-`subscribe` has already installed.
    private var armings: [PaneID: Int] = [:]
    private var nextArming = 0

    public init(
        socketPath: String,
        retryDelay: Duration = .seconds(2),
        probeTimeout: Duration = .seconds(3),
        onChange: @escaping @MainActor (PaneID, AgentStatus) -> Void
    ) {
        self.socketPath = socketPath
        self.retryDelay = retryDelay
        self.probeTimeout = probeTimeout
        self.onChange = onChange
    }

    public func subscribe(pane: PaneID) {
        guard feeds[pane] == nil else { return }
        let socketPath = socketPath
        let retryDelay = retryDelay
        let probeTimeout = probeTimeout
        let onChange = onChange
        nextArming += 1
        let arming = nextArming
        armings[pane] = arming
        feeds[pane] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let refused = await Self.runFeed(
                    pane: pane, socketPath: socketPath, probeTimeout: probeTimeout, onChange: onChange
                )
                if refused || Task.isCancelled { break }
                try? await Task.sleep(for: retryDelay)
            }
            // A refusal ends this pane's feed for good, but the slot must not
            // stay occupied by a finished task: `subscribe` is a no-op while
            // anything is in it, so the pane could never be armed again.
            // Every pane in the session is armed here, and a pane herdr
            // refused once (mid-close, say) is one the very next snapshot may
            // well report again.
            self?.retire(pane: pane, arming: arming)
        }
    }

    public func unsubscribe(pane: PaneID) {
        armings.removeValue(forKey: pane)
        feeds.removeValue(forKey: pane)?.cancel()
    }

    private func retire(pane: PaneID, arming: Int) {
        guard armings[pane] == arming else { return }
        armings.removeValue(forKey: pane)
        feeds.removeValue(forKey: pane)
    }

    /// Returns `true` when herdr refused the subscription, `false` when the
    /// connection simply ended or failed to open (both retryable).
    private static func runFeed(
        pane: PaneID, socketPath: String, probeTimeout: Duration,
        onChange: @MainActor (PaneID, AgentStatus) -> Void
    ) async -> Bool {
        guard let socket = try? await LineSocket(path: socketPath) else { return false }
        defer { Task { await socket.close() } }
        guard let request = subscribeLine(pane: pane), (try? await socket.send(line: request)) != nil else {
            return false
        }
        // AFTER the subscribe, never before: herdr seeds its own comparison
        // value when the subscription is created, so anything that changes
        // between these two reads still arrives as a frame. Probing first
        // would leave that window unreported by either side.
        if let seed = await probeStatus(pane: pane, socketPath: socketPath, timeout: probeTimeout), !Task.isCancelled {
            onChange(pane, seed)
        }
        do {
            for try await line in socket.lines {
                if Task.isCancelled { return false }
                if let (paneID, status) = HerdrDecoder.agentStatusChanged(fromLine: line) {
                    onChange(paneID, status)
                    continue
                }
                if ackRefused(line) { return true }
            }
        } catch {
            return false
        }
        return false
    }

    /// Reads the pane's current status on a connection of its OWN: herdr
    /// answers one request per connection and treats any inbound byte on a
    /// subscription connection as the peer disconnecting, so this can never
    /// share the feed's socket. A failure at any step simply yields no seed.
    ///
    /// Bounded, because the seed sits between the subscribe and the read
    /// loop: a `pane.get` that connects and then never answers would park
    /// that pane's whole feed with no retry behind it. Every pane in the
    /// session arms one of these at once, so one unanswerable pane must not
    /// be able to take its feed down with it. Giving up just means no seed --
    /// the model's own snapshot value stands until the first live frame.
    private static func probeStatus(pane: PaneID, socketPath: String, timeout: Duration) async -> AgentStatus? {
        await withTaskGroup(of: AgentStatus?.self) { group in
            group.addTask { await readProbe(pane: pane, socketPath: socketPath) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func readProbe(pane: PaneID, socketPath: String) async -> AgentStatus? {
        guard let socket = try? await LineSocket(path: socketPath) else { return nil }
        defer { Task { await socket.close() } }
        guard let request = probeLine(pane: pane), (try? await socket.send(line: request)) != nil else {
            return nil
        }
        do {
            for try await line in socket.lines {
                return HerdrDecoder.agentStatusProbe(fromLine: line)?.status
            }
        } catch {
            return nil
        }
        return nil
    }

    static func probeLine(pane: PaneID) -> Data? {
        struct Params: Encodable {
            let paneID: String
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
        struct Envelope: Encodable { let id: String; let method: String; let params: Params }
        let envelope = Envelope(
            id: "flock:agent:probe:\(pane.rawValue)",
            method: "pane.get",
            params: Params(paneID: pane.rawValue)
        )
        return try? JSONEncoder().encode(envelope)
    }

    static func subscribeLine(pane: PaneID) -> Data? {
        struct Subscription: Encodable {
            let type: String
            let paneID: String
            enum CodingKeys: String, CodingKey {
                case type
                case paneID = "pane_id"
            }
        }
        struct Params: Encodable { let subscriptions: [Subscription] }
        struct Envelope: Encodable { let id: String; let method: String; let params: Params }
        let envelope = Envelope(
            id: "flock:agent:\(pane.rawValue)",
            method: "events.subscribe",
            params: Params(subscriptions: [Subscription(type: "pane.agent_status_changed", paneID: pane.rawValue)])
        )
        return try? JSONEncoder().encode(envelope)
    }

    private static func ackRefused(_ line: Data) -> Bool {
        struct ErrorPeek: Decodable {
            struct Payload: Decodable { let code: String }
            let error: Payload?
        }
        return (try? JSONDecoder().decode(ErrorPeek.self, from: line))?.error != nil
    }
}
