import Foundation

/// The public pane id of each link's pane, by token. A herdr handoff gives
/// every pane a new terminal and keeps its pane id, so this is what finds a
/// link again after one; it lives here rather than in the tab label, which
/// older flock builds read as exactly three parts.
public struct RtLinkedPanes {
    static let key = "flock.rt.linkedPanes"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pane(for token: String) -> PaneID? {
        stored[token].map(PaneID.init(rawValue:))
    }

    func record(_ pane: PaneID, for token: String) {
        var panes = stored
        guard panes[token] != pane.rawValue else { return }
        panes[token] = pane.rawValue
        defaults.set(panes, forKey: Self.key)
    }

    func forget(_ token: String) {
        var panes = stored
        guard panes.removeValue(forKey: token) != nil else { return }
        defaults.set(panes, forKey: Self.key)
    }

    /// A link torn down while flock was not running leaves its entry behind;
    /// once launch has adopted what it will, nothing else can claim one.
    func keepOnly(_ tokens: Set<String>) {
        let panes = stored
        let kept = panes.filter { tokens.contains($0.key) }
        guard kept.count != panes.count else { return }
        defaults.set(kept, forKey: Self.key)
    }

    private var stored: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
