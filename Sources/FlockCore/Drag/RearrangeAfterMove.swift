import Foundation
import Observation

/// What rearrange mode does once a drag begun in it lands a real change.
/// Only a committed move counts: a cancel, a rejection or a drop that changes
/// nothing leaves the mode on, so a missed target can be tried again.
public enum RearrangeAfterMove: String, CaseIterable, Sendable {
    case leave
    case stay

    public var displayName: String {
        switch self {
        case .leave: "Exit"
        case .stay: "Stay"
        }
    }
}

/// The Settings choice, persisted across launches in the same UserDefaults
/// pattern as `OptionAsAltStore`.
@MainActor
@Observable
public final class RearrangeAfterMoveStore {
    public static let defaultsKey = "flock.rearrangeAfterMove"

    public private(set) var active: RearrangeAfterMove

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(RearrangeAfterMove.init(rawValue:)) ?? .leave
    }

    public func select(_ value: RearrangeAfterMove) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
