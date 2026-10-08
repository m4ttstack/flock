import Foundation
import Observation

public enum TopBarLabel: String, CaseIterable, Sendable {
    case iconOnly
    case iconAndName

    public var displayName: String {
        switch self {
        case .iconOnly: "Icon only"
        case .iconAndName: "Icon and name"
        }
    }
}

@MainActor
@Observable
public final class TopBarLabelStore {
    public static let defaultsKey = "flock.topBarLabel"

    public private(set) var label: TopBarLabel

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        label = userDefaults.string(forKey: Self.defaultsKey).flatMap(TopBarLabel.init(rawValue:)) ?? .iconOnly
    }

    public func select(_ value: TopBarLabel) {
        label = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
