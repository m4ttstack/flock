import Foundation

/// The attention stack's whole rule set: which transitions speak,
/// how a flapping pane is kept to one line, how deep the stack goes, and when
/// a finished toast stops being interesting.
///
/// Herdglass hands the same job to the OS notification centre, on the stated
/// grounds that "a GUI client has no toast layer and no outer terminal to ask".
/// flock has one, and it also sits beside the herdr TUI rather than
/// replacing it: a banner in Notification Center would double whatever herdr's
/// own `[ui.toast] delivery` is already doing for the same event, so the
/// attention surface stays inside flock's window.
public struct AttentionToastStack: Equatable, Codable, Sendable {
    /// Drawn however short the rail is; a taller rail draws more
    /// (`DockCapacity`), and past what it draws, older toasts are counted.
    public static let minimumVisible = 3
    /// A pane that changes again inside this window is flapping, not
    /// announcing something new.
    public static let coalescingWindow: TimeInterval = 2

    /// Newest first.
    public private(set) var toasts: [AttentionToast] = []

    public init() {}

    public var isEmpty: Bool { toasts.isEmpty }
    public func visible(limit: Int) -> [AttentionToast] { Array(toasts.prefix(max(0, limit))) }
    public func collapsedCount(limit: Int) -> Int { max(0, toasts.count - max(0, limit)) }
    /// The bottom card of the ones drawn, never one counted under the pill:
    /// a keystroke should open something the user can see.
    public func oldestVisible(limit: Int) -> AttentionToast? { visible(limit: limit).last }

    public func toast(pane: PaneID) -> AttentionToast? {
        toasts.first { $0.paneID == pane }
    }

    /// The two transitions the Interactions sheet raises a toast for, and
    /// nothing else. `nil` means stay quiet.
    public static func kind(from previous: AgentStatus, to current: AgentStatus) -> AttentionToast.Kind? {
        guard previous != current else { return nil }
        if current == .blocked { return .needsInput }
        if previous == .working, current == .idle || current == .done { return .finished }
        return nil
    }

    public enum RaiseOutcome: Equatable {
        case raised
        /// The pane already had a toast and changed again inside the
        /// coalescing window: the line was rewritten where it stood.
        case coalesced
        /// The pane already had a toast, but long enough ago that this is a
        /// new thing to say: it returns to the front with a fresh clock.
        case renewed
    }

    @discardableResult
    public mutating func raise(_ toast: AttentionToast) -> RaiseOutcome {
        guard let index = toasts.firstIndex(where: { $0.paneID == toast.paneID }) else {
            toasts.insert(toast, at: 0)
            return .raised
        }
        let live = toasts[index]
        // Deliberately keeps `raisedAt`: a flap must not re-sort the stack
        // under a pointer that is already on it, and must not hand a finished
        // toast a fresh lifetime every time the agent twitches.
        guard toast.raisedAt.timeIntervalSince(live.raisedAt) >= Self.coalescingWindow else {
            var coalesced = toast
            coalesced.raisedAt = live.raisedAt
            toasts[index] = coalesced
            return .coalesced
        }
        toasts.remove(at: index)
        toasts.insert(toast, at: 0)
        return .renewed
    }

    public mutating func dismiss(pane: PaneID) {
        toasts.removeAll { $0.paneID == pane }
    }

    public mutating func clear() {
        toasts.removeAll()
    }

    /// Drops every finished toast older than `lifetime`. A `needsInput`
    /// toast has no lifetime: it is a question nobody has answered yet.
    public mutating func expire(at now: Date, after lifetime: TimeInterval) {
        toasts.removeAll { $0.kind == .finished && now.timeIntervalSince($0.raisedAt) >= lifetime }
    }
}
