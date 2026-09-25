import Foundation
import Observation

/// The commands run from the palette, most recent first, kept across
/// launches the way `RtModalSizeStore` keeps its size.
@MainActor
@Observable
public final class PaletteRecentsStore {
    public static let defaultsKey = "flock.paletteRecents"
    public static let storedLimit = 20

    public private(set) var ids: [String]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        ids = userDefaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    public func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.storedLimit { ids.removeLast(ids.count - Self.storedLimit) }
        userDefaults.set(ids, forKey: Self.defaultsKey)
    }
}
