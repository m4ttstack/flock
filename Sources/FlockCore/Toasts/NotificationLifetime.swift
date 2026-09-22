import Foundation
import Observation

/// How long the dock's attention cards stay, from Settings.
///
/// Every card leaves once herdr clears the status it announced (see
/// `SessionViewModel.withdrawSettledAttentionToasts`); this only decides
/// whether a "finished" card may also leave on a timer, and whether cards
/// are raised at all. A "needs input" card never times out: it is a question
/// nobody has answered yet.
public enum NotificationLifetime: String, CaseIterable, Sendable {
    case untilSeen
    case fiveSeconds
    case never

    public var displayName: String {
        switch self {
        case .untilSeen: "Until seen"
        case .fiveSeconds: "For 5 seconds"
        case .never: "Never"
        }
    }

    /// nil for a card that waits for its pane to be seen.
    public var finishedLifetime: TimeInterval? {
        switch self {
        case .fiveSeconds: 5
        case .untilSeen, .never: nil
        }
    }
}

/// The Settings choice, persisted across launches in the same UserDefaults
/// pattern as `OptionAsAltStore`.
@MainActor
@Observable
public final class NotificationLifetimeStore {
    public static let defaultsKey = "flock.notificationLifetime"

    public private(set) var active: NotificationLifetime

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(NotificationLifetime.init(rawValue:)) ?? .untilSeen
    }

    public func select(_ value: NotificationLifetime) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
