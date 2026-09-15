/// Which `pane.read` last-line fetches go out and which replies still count.
/// A pane's line is fetched once per `PaneRecord.revision`, and a reply for a
/// revision the pane has since moved past is stale even if it lands last.
public struct LastLineRequests: Equatable, Sendable {
    private var latest: [PaneID: Int] = [:]

    public init() {}

    /// True only the first time `revision` is asked for, which is the one
    /// call that should fetch.
    public mutating func begin(pane: PaneID, revision: Int) -> Bool {
        guard latest[pane] != revision else { return false }
        latest[pane] = revision
        return true
    }

    public func accepts(pane: PaneID, revision: Int) -> Bool {
        latest[pane] == revision
    }
}
