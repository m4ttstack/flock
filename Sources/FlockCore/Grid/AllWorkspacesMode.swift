import Foundation
import Observation

public enum AllWorkspacesMode: String, CaseIterable, Sendable {
    case missionControl
    case arrange

    public var title: String {
        switch self {
        case .missionControl: "Overview"
        case .arrange: "Arrange"
        }
    }
}

/// The All Workspaces view's mode, remembered across launches so ⇧⌘R opens
/// where it was left.
@MainActor
@Observable
public final class AllWorkspacesModeStore {
    public static let defaultsKey = "flock.allWorkspacesMode"

    public private(set) var active: AllWorkspacesMode
    /// The selected Overview card, kept while the view is closed so Overview
    /// reopens on it.
    public var missionSelection: PaneID?
    /// At rest's Older section, open or folded as it was left. Read only
    /// while Older is long enough to fold.
    public var opensOlder = false
    /// The same for the Earlier section, panes with no known last change.
    public var opensEarlier = false

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(AllWorkspacesMode.init(rawValue:)) ?? .missionControl
    }

    /// Set for an open that began mid-drag: the drop surface is always
    /// Arrange, and the view stays there after the drop until the person picks
    /// a mode. Never remembered.
    public private(set) var heldInArrange = false

    public func select(_ mode: AllWorkspacesMode) {
        heldInArrange = false
        active = mode
        userDefaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }

    public func opened(dragInFlight: Bool) {
        heldInArrange = dragInFlight
    }

    /// The mode drawn now, which a live drag forces to Arrange whatever is
    /// remembered.
    public func shown(dragInFlight: Bool) -> AllWorkspacesMode {
        dragInFlight || heldInArrange ? .arrange : active
    }
}
