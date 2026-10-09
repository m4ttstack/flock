import Foundation
import Observation

/// Which symbol (a name from `WorkspaceSymbols.all`) marks each workspace.
/// Keyed by workspace id so a rename keeps the symbol. Board's workspaces
/// share one key; herds have none and draw the ram.
@MainActor
@Observable
public final class WorkspaceIdentityStore {
    public static let defaultsKey = "flock.workspaceSymbol"
    public nonisolated static let boardKey = "section:board"

    public private(set) var assigned: [String: String]
    public private(set) var overrides: [String: String]

    @ObservationIgnored private let userDefaults: UserDefaults

    private struct Stored: Codable {
        var assigned: [String: String]
        var overrides: [String: String]
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        assigned = (stored?.assigned ?? [:]).filter { WorkspaceSymbols.contains($0.value) }
        overrides = (stored?.overrides ?? [:]).filter { WorkspaceSymbols.contains($0.value) }
    }

    public static func key(for workspace: WorkspaceID, sections: RailSections) -> String? {
        if let row = sections.pinned.first(where: { $0.record?.workspaceID == workspace }) { return row.pin.identityKey }
        if sections.herds.contains(where: { $0.workspaceID == workspace }) { return nil }
        if sections.board.contains(where: { $0.workspaceID == workspace }) { return boardKey }
        return workspace.rawValue
    }

    /// Whether `key` names one of the rail's own workspace rows, the only ones
    /// with a menu and a rename: Board's workspaces and herds sit in sections
    /// of their own.
    public static func isRailRow(key: String?) -> Bool {
        key != nil && key != boardKey
    }

    /// Every pin first, empty ones included, so a closed place keeps its
    /// symbol; then every other key the rail shows, in rail order.
    public static func keys(in sections: RailSections) -> [String] {
        var seen = Set<String>()
        let pins = (sections.pinned + sections.topBar).map(\.pin.identityKey)
        let rest = sections.railOrder.compactMap { key(for: $0, sections: sections) }
        return (pins + rest).filter { seen.insert($0).inserted }
    }

    /// Carries a symbol across a pin or unpin.
    public func rekey(from old: String, to new: String) {
        guard old != new else { return }
        if let name = assigned.removeValue(forKey: old) { assigned[new] = name }
        if let name = overrides.removeValue(forKey: old) { overrides[new] = name }
        save()
    }

    public func symbol(for key: String) -> String? {
        overrides[key] ?? assigned[key]
    }

    /// Gives each key without a symbol the least used one, the earliest in
    /// the set breaking ties; overrides count as uses.
    public func assign(_ keys: [String]) {
        var next = assigned
        let names = WorkspaceSymbols.all.map(\.name)
        for key in keys where next[key] == nil {
            var uses = Array(repeating: 0, count: names.count)
            for other in Set(next.keys).union(overrides.keys) {
                if let name = overrides[other] ?? next[other], let index = names.firstIndex(of: name) { uses[index] += 1 }
            }
            let least = uses.indices.min { (uses[$0], $0) < (uses[$1], $1) } ?? 0
            next[key] = names[least]
        }
        guard next != assigned else { return }
        assigned = next
        save()
    }

    public func setOverride(_ name: String?, for key: String) {
        if let name, !WorkspaceSymbols.contains(name) { return }
        overrides[key] = name
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

    /// Drops keys no longer shown and assigns the new ones. Run by every view
    /// that draws marks, since whichever appears first meets a new workspace.
    public func refresh(_ sections: RailSections) {
        let keys = Self.keys(in: sections)
        guard !keys.isEmpty else { return }
        keepOnly(Set(keys))
        assign(keys)
    }

    private func save() {
        let data = try? JSONEncoder().encode(Stored(assigned: assigned, overrides: overrides))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
