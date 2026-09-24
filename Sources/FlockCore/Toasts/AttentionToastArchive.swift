import Foundation

/// The dock's attention cards, kept across launches in the same UserDefaults
/// pattern as `NotificationLifetimeStore`.
///
/// What comes back is only a claim about panes as they were at quit: the
/// first snapshot after launch runs it through
/// `SessionViewModel.withdrawSettledAttentionToasts` like any other card, so
/// a pane herdr no longer reports, or a question answered while flock was
/// closed, never reaches the dock.
@MainActor
public final class AttentionToastArchive {
    public static let defaultsKey = "flock.attentionToasts"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// An empty stack for anything unreadable, an archive from a build whose
    /// toast shape has since changed included.
    public func load() -> AttentionToastStack {
        userDefaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(AttentionToastStack.self, from: $0) }
            ?? AttentionToastStack()
    }

    public func save(_ stack: AttentionToastStack) {
        guard !stack.isEmpty else {
            userDefaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(stack) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
