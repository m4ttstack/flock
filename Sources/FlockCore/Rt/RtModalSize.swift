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

/// Holds the rt modal's size, one per rt command, persisted across launches,
/// mirroring `ScrollSpeedStore`'s UserDefaults pattern. A command never sized
/// on its own opens at the one size every modal shared before (`legacyDefaultsKey`);
/// a size this build does not know reads as `medium`.
@MainActor
@Observable
public final class RtModalSizeStore {
    public static let legacyDefaultsKey = "flock.rtModalSize"

    public static func defaultsKey(for kind: RtKind) -> String { "\(legacyDefaultsKey).\(kind.rawValue)" }

    public private(set) var sizes: [RtKind: RtModalSize]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let shared = userDefaults.string(forKey: Self.legacyDefaultsKey).flatMap(RtModalSize.init(rawValue:))
        sizes = Dictionary(uniqueKeysWithValues: RtKind.allCases.map { kind in
            let own = userDefaults.string(forKey: Self.defaultsKey(for: kind)).flatMap(RtModalSize.init(rawValue:))
            return (kind, own ?? shared ?? .medium)
        })
    }

    public func size(for kind: RtKind) -> RtModalSize { sizes[kind] ?? .medium }

    public func select(_ size: RtModalSize, for kind: RtKind) {
        sizes[kind] = size
        userDefaults.set(size.rawValue, forKey: Self.defaultsKey(for: kind))
    }
}
