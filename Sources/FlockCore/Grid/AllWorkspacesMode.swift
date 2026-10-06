import Foundation
import Observation

public enum AllWorkspacesMode: String, CaseIterable, Sendable {
    case missionControl
    case arrange

    public var title: String {
        switch self {
        case .missionControl: "Mission control"
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
    /// The selected mission-control card, kept while the view is closed so
    /// Jump Back reopens on it.
    public var missionSelection: PaneID?

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(AllWorkspacesMode.init(rawValue:)) ?? .missionControl
    }

    public func select(_ mode: AllWorkspacesMode) {
        active = mode
        userDefaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
