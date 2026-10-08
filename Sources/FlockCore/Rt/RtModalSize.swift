import Foundation
import Observation

/// Holds the rt modal's size, one per rt command, persisted across launches,
/// mirroring `ScrollSpeedStore`'s UserDefaults pattern. A command never sized
/// on its own opens at the one size every modal shared before (`legacyDefaultsKey`);
/// a size this build does not know reads as `medium`.
@MainActor
@Observable
public final class RtModalSizeStore {
    public static let legacyDefaultsKey = "flock.rtModalSize"

    public static func defaultsKey(for kind: RtKind) -> String { "\(legacyDefaultsKey).\(kind.rawValue)" }

    public private(set) var sizes: [RtKind: ModalSize]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let shared = userDefaults.string(forKey: Self.legacyDefaultsKey).flatMap(ModalSize.init(rawValue:))
        sizes = Dictionary(uniqueKeysWithValues: RtKind.allCases.map { kind in
            let own = userDefaults.string(forKey: Self.defaultsKey(for: kind)).flatMap(ModalSize.init(rawValue:))
            return (kind, own ?? shared ?? .medium)
        })
    }

    public func size(for kind: RtKind) -> ModalSize { sizes[kind] ?? .medium }

    public func select(_ size: ModalSize, for kind: RtKind) {
        sizes[kind] = size
        userDefaults.set(size.rawValue, forKey: Self.defaultsKey(for: kind))
    }
}
