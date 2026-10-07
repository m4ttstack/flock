import Foundation
import Observation

/// What an Overview card's second line says about where its pane works,
/// from Settings > Overview > "Bottom line".
public enum MissionBottomLine: String, CaseIterable, Sendable {
    case branch
    case repoAndBranch
    case hidden

    public var displayName: String {
        switch self {
        case .branch: "Branch"
        case .repoAndBranch: "Repo and branch"
        case .hidden: "Hidden"
        }
    }

    /// nil when the line shows no text. `.branch` drops the repository when it
    /// is named like the workspace, which already labels the card's group; a
    /// folder outside any repository has no branch and keeps its name.
    public func text(_ value: RepoBranch, workspace: String) -> String? {
        switch self {
        case .hidden:
            return nil
        case .repoAndBranch:
            return value.text
        case .branch:
            guard let branch = value.branch, value.repo.caseInsensitiveCompare(workspace) == .orderedSame else { return value.text }
            return branch
        }
    }
}

/// The Settings choice, persisted like `NotificationLifetimeStore`.
@MainActor
@Observable
public final class MissionBottomLineStore {
    public static let defaultsKey = "flock.overviewBottomLine"

    public private(set) var active: MissionBottomLine

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.string(forKey: Self.defaultsKey).flatMap(MissionBottomLine.init(rawValue:)) ?? .branch
    }

    public func select(_ value: MissionBottomLine) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
