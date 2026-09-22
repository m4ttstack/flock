import Foundation
import Observation

/// How long the dock's attention cards stay, from Settings.
///
/// Only a "finished" card ever leaves on its own. A "needs input" card is a
/// question nobody has answered yet, so it stays until the pane stops
/// waiting under every setting but `off`, which raises no cards at all.
public enum NotificationLifetime: String, CaseIterable, Sendable {
    case stayUntilDismissed
    case fiveSeconds
    case off

    public var displayName: String {
        switch self {
        case .stayUntilDismissed: "Stay until dismissed"
        case .fiveSeconds: "Hide after 5 seconds"
        case .off: "Off"
        }
    }

    /// nil for a card that waits to be dismissed or read.
    public var finishedLifetime: TimeInterval? {
        switch self {
        case .fiveSeconds: 5
        case .stayUntilDismissed, .off: nil
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
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(NotificationLifetime.init(rawValue:)) ?? .fiveSeconds
    }

    public func select(_ value: NotificationLifetime) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
