import Foundation
import Observation

/// Which identity hue (an index into `IdentityPalette.colors`) each
/// workspace wears. Keyed by workspace id so a rename keeps the colour.
/// Board's workspaces share one key; herds have none and draw neutral.
@MainActor
@Observable
public final class WorkspaceIdentityStore {
    public static let defaultsKey = "flock.workspaceIdentity"
    public static let boardKey = "section:board"

    public private(set) var assigned: [String: Int]
    public private(set) var overrides: [String: Int]

    @ObservationIgnored private let userDefaults: UserDefaults

    private struct Stored: Codable {
        var assigned: [String: Int]
        var overrides: [String: Int]
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        assigned = stored?.assigned ?? [:]
        overrides = stored?.overrides ?? [:]
    }

    public static func key(for workspace: WorkspaceID, sections: RailSections) -> String? {
        if sections.herds.contains(where: { $0.workspaceID == workspace }) { return nil }
        if sections.board.contains(where: { $0.workspaceID == workspace }) { return boardKey }
        return workspace.rawValue
    }

    public func index(for key: String) -> Int? {
        overrides[key] ?? assigned[key]
    }

    /// Gives each key without a hue the least used one, lowest index first; overrides count as uses.
    public func assign(_ keys: [String]) {
        var next = assigned
        for key in keys where next[key] == nil {
            var uses = Array(repeating: 0, count: IdentityPalette.count)
            for key in Set(next.keys).union(overrides.keys) {
                if let index = overrides[key] ?? next[key], uses.indices.contains(index) { uses[index] += 1 }
            }
            next[key] = uses.indices.min { (uses[$0], $0) < (uses[$1], $1) } ?? 0
        }
        guard next != assigned else { return }
        assigned = next
        save()
    }

    public func setOverride(_ index: Int?, for key: String) {
        if let index, !(0..<IdentityPalette.count).contains(index) { return }
        overrides[key] = index
        save()
    }

    public func keepOnly(_ keys: Set<String>) {
        let keep = keys.union([Self.boardKey])
        let nextAssigned = assigned.filter { keep.contains($0.key) }
        let nextOverrides = overrides.filter { keep.contains($0.key) }
        guard nextAssigned != assigned || nextOverrides != overrides else { return }
        assigned = nextAssigned
        overrides = nextOverrides
        save()
    }

    private func save() {
        let data = try? JSONEncoder().encode(Stored(assigned: assigned, overrides: overrides))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
