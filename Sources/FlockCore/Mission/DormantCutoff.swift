import Foundation
import Observation

/// How long a pane can go without a status change before mission control
/// folds it away, from Settings.
public enum DormantCutoff: Int, CaseIterable, Sendable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case twoHours = 120

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    public var displayName: String {
        switch self {
        case .fifteen, .thirty: "\(rawValue) minutes"
        case .sixty: "1 hour"
        case .twoHours: "2 hours"
        }
    }
}

/// The Settings choice, persisted like `NotificationLifetimeStore`.
@MainActor
@Observable
public final class DormantCutoffStore {
    public static let defaultsKey = "flock.dormantCutoff"

    public private(set) var active: DormantCutoff

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = DormantCutoff(rawValue: userDefaults.integer(forKey: Self.defaultsKey)) ?? .thirty
    }

    public func select(_ value: DormantCutoff) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
