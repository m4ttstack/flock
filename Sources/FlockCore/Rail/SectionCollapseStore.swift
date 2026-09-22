import Foundation
import Observation

/// A rail section that folds under its own header.
public enum RailSection: CaseIterable, Sendable {
    case board
    case herds

    /// Each section's own key. Herds' is the key it had before Board existed,
    /// so a fold made then is still read now.
    var defaultsKey: String {
        switch self {
        case .board: "flock.boardCollapsed"
        case .herds: "flock.herdsCollapsed"
        }
    }
}

/// Whether each rail section is folded, across launches. Mirrors
/// `RailWidthStore`'s UserDefaults pattern, and is injected the same way.
/// Nothing but `toggle` writes it: a section whose rows appear while it is
/// folded stays folded, and its header is the notice.
@MainActor
@Observable
public final class SectionCollapseStore {
    private var collapsed: Set<RailSection>
    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        collapsed = Set(RailSection.allCases.filter { userDefaults.bool(forKey: $0.defaultsKey) })
    }

    public func isCollapsed(_ section: RailSection) -> Bool {
        collapsed.contains(section)
    }

    public func toggle(_ section: RailSection) {
        if collapsed.remove(section) == nil { collapsed.insert(section) }
        userDefaults.set(collapsed.contains(section), forKey: section.defaultsKey)
    }
}
