import Foundation
import Observation

/// Settings › Views: whether Overview's lanes include Board's review
/// workspaces and the herds'. Both are included until turned off.
@MainActor
@Observable
public final class OverviewInclusionStore {
    public static let reviewsKey = "flock.overview.includesReviews"
    public static let herdsKey = "flock.overview.includesHerds"

    public private(set) var includesReviews: Bool
    public private(set) var includesHerds: Bool

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        includesReviews = userDefaults.object(forKey: Self.reviewsKey) as? Bool ?? true
        includesHerds = userDefaults.object(forKey: Self.herdsKey) as? Bool ?? true
    }

    public func setIncludesReviews(_ value: Bool) {
        includesReviews = value
        userDefaults.set(value, forKey: Self.reviewsKey)
    }

    public func setIncludesHerds(_ value: Bool) {
        includesHerds = value
        userDefaults.set(value, forKey: Self.herdsKey)
    }

    /// The workspaces Overview leaves out of `sections`.
    public func excluded(from sections: RailSections) -> Set<WorkspaceID> {
        (includesReviews ? [] : sections.reviewIDs).union(includesHerds ? [] : sections.herdIDs)
    }
}
