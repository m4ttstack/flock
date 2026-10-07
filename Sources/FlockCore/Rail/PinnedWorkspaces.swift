import Foundation
import Observation

public struct PinID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> PinID { PinID(rawValue: UUID().uuidString) }
}

/// A place the person keeps: it outlives the herdr workspace it is linked to.
public struct PinnedWorkspace: Equatable, Codable, Sendable, Identifiable {
    public let id: PinID
    public var name: String
    public var folder: String
    /// nil while nothing is open for the pin.
    public var workspace: WorkspaceID?
    /// herdr's label for `workspace` when last reconciled. nil right after a
    /// link from a create, so the first label seen is taken without renaming
    /// the pin: it is herdr's default until the rename lands.
    public var syncedLabel: String?
    /// Whether herdr has reported `workspace` since it was linked. A create's
    /// reply links before any snapshot carries the workspace, and that gap is
    /// not the workspace closing.
    public var confirmed: Bool

    public var identityKey: String { "pin:\(id.rawValue)" }
}

extension PinnedWorkspace {
    /// The switcher lists by workspace id; an empty pin has none, so it takes
    /// one herdr never issues.
    public var switcherID: WorkspaceID { WorkspaceID(rawValue: identityKey) }
}

extension PinID {
    public init?(switcherID: WorkspaceID) {
        guard switcherID.rawValue.hasPrefix("pin:") else { return nil }
        self.init(rawValue: String(switcherID.rawValue.dropFirst(4)))
    }
}

public enum PinNames {
    public static func matches(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum PinFolders {
    /// The folder of the first pane of the workspace's first tab, as it is:
    /// never widened to its repo, since one repo can hold many places.
    public static func firstPane(of workspace: WorkspaceID, in model: SessionModel) -> String? {
        guard let tab = model.tabs[workspace]?.first else { return nil }
        let inLayout = (model.layouts[tab.tabID]?.panes ?? []).lazy.compactMap { model.panes[$0.paneID] }.first
        let pane = inLayout ?? model.panes.values
            .filter { $0.tabID == tab.tabID }
            .min { $0.paneID.rawValue < $1.paneID.rawValue }
        return pane.map { $0.foregroundCwd ?? $0.cwd }
    }
}

@MainActor
@Observable
public final class PinnedWorkspaceStore {
    public static let defaultsKey = "flock.pinnedWorkspaces"

    public private(set) var pins: [PinnedWorkspace]

    @ObservationIgnored private let userDefaults: UserDefaults?

    private struct Stored: Codable {
        var version: Int
        var pins: [PinnedWorkspace]
    }

    /// nil keeps the pins in memory only.
    public init(userDefaults: UserDefaults?) {
        self.userDefaults = userDefaults
        pins = userDefaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            .map(\.pins) ?? []
    }

    public func pin(_ id: PinID) -> PinnedWorkspace? {
        pins.first { $0.id == id }
    }

    public func pin(linkedTo workspace: WorkspaceID) -> PinnedWorkspace? {
        pins.first { $0.workspace == workspace }
    }

    public func isNameTaken(_ name: String, except: PinID?) -> Bool {
        pins.contains { $0.id != except && PinNames.matches($0.name, name) }
    }

    @discardableResult
    public func add(workspace: WorkspaceID, name: String, folder: String, at index: Int?) -> PinnedWorkspace? {
        guard pin(linkedTo: workspace) == nil, !isNameTaken(name, except: nil) else { return nil }
        let pin = PinnedWorkspace(
            id: .make(), name: name, folder: folder, workspace: workspace, syncedLabel: name, confirmed: true
        )
        pins.insert(pin, at: min(max(index ?? pins.count, 0), pins.count))
        save()
        return pin
    }

    public func remove(_ id: PinID) {
        pins.removeAll { $0.id == id }
        save()
    }

    /// `index` counts the pins as drawn, the moving one included.
    public func move(_ id: PinID, toInsertIndex index: Int) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        var next = pins
        let moving = next.remove(at: from)
        let target = index > from ? index - 1 : index
        next.insert(moving, at: min(max(target, 0), next.count))
        guard next != pins else { return }
        pins = next
        save()
    }

    public func rename(_ id: PinID, to name: String) -> Bool {
        guard let index = pins.firstIndex(where: { $0.id == id }), !isNameTaken(name, except: id) else { return false }
        pins[index].name = name
        save()
        return true
    }

    public func setFolder(_ id: PinID, to folder: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].folder = folder
        save()
    }

    /// Links from a create's reply, before any snapshot carries the workspace.
    public func link(_ id: PinID, to workspace: WorkspaceID) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].workspace = workspace
        pins[index].syncedLabel = nil
        pins[index].confirmed = false
        save()
    }

    /// Keeps links that herdr still reports (names following its renames),
    /// empties pins whose workspace herdr has shown and no longer does, then
    /// lets each empty pin adopt the first unlinked `eligible` workspace with
    /// its name.
    public func reconcile(with model: SessionModel, eligible: (WorkspaceRecord) -> Bool) {
        var next = pins
        var records: [WorkspaceID: WorkspaceRecord] = [:]
        for record in model.workspaces where records[record.workspaceID] == nil { records[record.workspaceID] = record }
        for index in next.indices {
            guard let workspace = next[index].workspace else { continue }
            if let record = records[workspace] {
                next[index].confirmed = true
                if let synced = next[index].syncedLabel, synced != record.label,
                   !next.contains(where: { $0.id != next[index].id && PinNames.matches($0.name, record.label) }) {
                    next[index].name = record.label
                }
                next[index].syncedLabel = record.label
            } else if next[index].confirmed {
                next[index].workspace = nil
                next[index].syncedLabel = nil
                next[index].confirmed = false
            }
        }
        var linked = Set(next.compactMap(\.workspace))
        for index in next.indices where next[index].workspace == nil {
            guard let record = model.workspaces.first(where: {
                !linked.contains($0.workspaceID) && eligible($0) && PinNames.matches($0.label, next[index].name)
            }) else { continue }
            next[index].workspace = record.workspaceID
            next[index].syncedLabel = record.label
            next[index].confirmed = true
            linked.insert(record.workspaceID)
        }
        guard next != pins else { return }
        pins = next
        save()
    }

    private func save() {
        guard let userDefaults else { return }
        let data = try? JSONEncoder().encode(Stored(version: 1, pins: pins))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
