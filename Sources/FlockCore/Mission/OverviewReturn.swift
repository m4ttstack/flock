import Foundation
import Observation

/// What Overview shows when you come back to it from Workspaces after leaving
/// with a pane open, from Settings > Overview.
public enum OverviewReturn: String, CaseIterable, Sendable {
    case lanes
    case openPane

    public var displayName: String {
        switch self {
        case .lanes: "The lanes"
        case .openPane: "The pane you had open"
        }
    }
}

/// The Settings choice, persisted like `MissionBottomLineStore`.
@MainActor
@Observable
public final class OverviewReturnStore {
    public static let defaultsKey = "flock.overviewReturn"

    public private(set) var active: OverviewReturn

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(OverviewReturn.init(rawValue:)) ?? .lanes
    }

    public func select(_ value: OverviewReturn) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
