import Foundation

/// The per-pane scroll feed `SessionViewModel` arms for every visible pane
/// and disarms when the pane parks or is torn down. A fake stands in for it
/// in `SessionViewModelTests`.
@MainActor
public protocol PaneScrollSubscribing: AnyObject {
    func subscribe(pane: PaneID)
    func unsubscribe(pane: PaneID)
}

/// One `events.subscribe` connection per attached pane, carrying exactly one
/// `pane.scroll_changed` subscription for that pane id, plus a `pane.get`
/// probe of its own once the subscription is up. Pane-scoped types can never
/// ride the blanket subscription: herdr probes the pane at subscribe time and
/// fails the WHOLE subscribe request if it is gone, and polls it with a
/// `pane.get` on every tick after, so each pane gets its own connection whose
/// life is exactly its visible life. herdr emits a frame only when the scroll
/// state actually CHANGES from the value that subscribe-time probe seeded
/// (`ActiveScrollChangedSubscription`), which is why the feed reads the
/// current state itself: a pane scrolled back while paddock was not watching
/// it would otherwise show no indicator until it moved again.
///
/// A connection that drops (herdr restarting, the pane closing) is retried
/// after a pause until `unsubscribe`; a subscribe the server refuses (an
/// error ack) ends the feed for that pane outright, since retrying a pane
/// herdr no longer knows would never succeed.
@MainActor
public final class HerdrPaneScrollSubscriber: PaneScrollSubscribing {
    private let socketPath: String
    private let onChange: @MainActor (PaneID, ScrollInfo) -> Void
    private let retryDelay: Duration
    private var feeds: [PaneID: Task<Void, Never>] = [:]
    /// Which arming a pane's slot currently holds, so a feed that ends can
    /// clear its own slot without ever clearing a newer one that a
    /// re-`subscribe` has already installed.
    private var armings: [PaneID: Int] = [:]
    private var nextArming = 0

    public init(
        socketPath: String,
        retryDelay: Duration = .seconds(2),
        onChange: @escaping @MainActor (PaneID, ScrollInfo) -> Void
    ) {
        self.socketPath = socketPath
        self.retryDelay = retryDelay
        self.onChange = onChange
    }

    public func subscribe(pane: PaneID) {
        guard feeds[pane] == nil else { return }
        let socketPath = socketPath
        let retryDelay = retryDelay
        let onChange = onChange
        nextArming += 1
        let arming = nextArming
        armings[pane] = arming
        feeds[pane] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let refused = await Self.runFeed(pane: pane, socketPath: socketPath, onChange: onChange)
                if refused || Task.isCancelled { break }
                try? await Task.sleep(for: retryDelay)
            }
            // A refusal ends this pane's feed for good, but the slot must not
            // stay occupied by a finished task: `subscribe` is a no-op while
            // anything is in it, so the pane could never be armed again. The
            // next attach of a pane herdr refused once (mid-close, say) is
            // exactly that second arming.
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
        pane: PaneID, socketPath: String, onChange: @MainActor (PaneID, ScrollInfo) -> Void
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
        if let seed = await probeScroll(pane: pane, socketPath: socketPath), !Task.isCancelled {
            onChange(pane, seed)
        }
        do {
            for try await line in socket.lines {
                if Task.isCancelled { return false }
                if let (paneID, scroll) = HerdrDecoder.scrollChanged(fromLine: line) {
                    onChange(paneID, scroll)
                    continue
                }
                if ackRefused(line) { return true }
            }
        } catch {
            return false
        }
        return false
    }

    /// Reads the pane's current scroll state on a connection of its OWN:
    /// herdr answers one request per connection and treats any inbound byte on
    /// a subscription connection as the peer disconnecting, so this can never
    /// share the feed's socket. A failure at any step simply yields no seed.
    private static func probeScroll(pane: PaneID, socketPath: String) async -> ScrollInfo? {
        guard let socket = try? await LineSocket(path: socketPath) else { return nil }
        defer { Task { await socket.close() } }
        guard let request = probeLine(pane: pane), (try? await socket.send(line: request)) != nil else {
            return nil
        }
        do {
            for try await line in socket.lines {
                return HerdrDecoder.scrollProbe(fromLine: line)?.scroll
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
            id: "paddock:scroll:probe:\(pane.rawValue)",
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
            id: "paddock:scroll:\(pane.rawValue)",
            method: "events.subscribe",
            params: Params(subscriptions: [Subscription(type: "pane.scroll_changed", paneID: pane.rawValue)])
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
