import Foundation
import Observation

/// The top-bar overlay's size, one per pin, in the shared modal's three sizes.
@MainActor
@Observable
public final class TopBarOverlaySizeStore {
    public static let defaultsKey = "flock.topBarOverlaySize"

    public private(set) var sizes: [PinID: ModalSize]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let raw = userDefaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        sizes = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            ModalSize(rawValue: value).map { (PinID(rawValue: key), $0) }
        })
    }

    public func size(for pin: PinID) -> ModalSize { sizes[pin] ?? .medium }

    public func select(_ size: ModalSize, for pin: PinID) {
        sizes[pin] = size
        save()
    }

    public func forget(_ pin: PinID) {
        guard sizes.removeValue(forKey: pin) != nil else { return }
        save()
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, $0.value.rawValue) })
        userDefaults.set(try? JSONEncoder().encode(raw), forKey: Self.defaultsKey)
    }
}
