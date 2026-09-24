import Foundation
import Observation

/// How much of the tab area the rt modal's box takes.
public enum RtModalSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Holds the rt modal's size, persisted across launches, mirroring
/// `ScrollSpeedStore`'s UserDefaults pattern; a size this build does not know
/// reads as `medium`.
@MainActor
@Observable
public final class RtModalSizeStore {
    public static let defaultsKey = "flock.rtModalSize"

    public private(set) var active: RtModalSize

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.string(forKey: Self.defaultsKey)
        active = stored.flatMap(RtModalSize.init(rawValue:)) ?? .medium
    }

    public func select(_ size: RtModalSize) {
        active = size
        userDefaults.set(size.rawValue, forKey: Self.defaultsKey)
    }
}
