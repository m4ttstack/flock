import Foundation

/// Each pane's last status change, kept across launches so At rest still
/// knows how long a pane has been quiet. Persisted like
/// `AttentionToastArchive`.
///
/// A record is only a claim about the pane as it was at quit:
/// `PaneStatusHistory.observe` takes its date only while the pane still
/// holds the recorded status.
@MainActor
public final class PaneLastChangeArchive {
    public static let defaultsKey = "flock.paneLastChange"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Empty for anything unreadable.
    public func load() -> [PaneID: PaneStatusHistory.Transition] {
        userDefaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([PaneID: PaneStatusHistory.Transition].self, from: $0) }
            ?? [:]
    }

    public func save(_ changes: [PaneID: PaneStatusHistory.Transition]) {
        guard !changes.isEmpty else {
            userDefaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(changes) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
