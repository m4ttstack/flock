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
/// `pane.scroll_changed` subscription for that pane id. Pane-scoped types
/// can never ride the blanket subscription: herdr probes the pane at
/// subscribe time and fails the WHOLE subscribe request if it is gone, and
/// polls it with a `pane.get` on every tick after, so each pane gets its own
/// connection whose life is exactly its visible life. herdr emits a frame
/// only when the scroll state actually changes (`ActiveScrollChangedSubscription`).
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
        feeds[pane] = Task { @MainActor in
            while !Task.isCancelled {
                let refused = await Self.runFeed(pane: pane, socketPath: socketPath, onChange: onChange)
                if refused || Task.isCancelled { return }
                try? await Task.sleep(for: retryDelay)
            }
        }
    }

    public func unsubscribe(pane: PaneID) {
        feeds.removeValue(forKey: pane)?.cancel()
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
