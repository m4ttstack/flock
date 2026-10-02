import Foundation
import Observation

/// The tabs marked complete from their right-click menu, a mark flock alone
/// draws: herdr never hears of it. Mirrors `RightClickModeStore`'s
/// UserDefaults pattern; `userDefaults` nil keeps it in memory.
@MainActor
@Observable
public final class TabCompletionStore {
    public static let defaultsKey = "flock.completedTabs"

    private var completed: Set<TabID>
    @ObservationIgnored private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults
        let stored = userDefaults?.stringArray(forKey: Self.defaultsKey) ?? []
        completed = Set(stored.map(TabID.init(rawValue:)))
    }

    public func isComplete(_ tab: TabID) -> Bool {
        completed.contains(tab)
    }

    public func toggle(_ tab: TabID) {
        if completed.remove(tab) == nil { completed.insert(tab) }
        save()
    }

    public func keepOnly(_ present: Set<TabID>) {
        let kept = completed.intersection(present)
        guard kept != completed else { return }
        completed = kept
        save()
    }

    private func save() {
        userDefaults?.set(completed.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
    }
}
