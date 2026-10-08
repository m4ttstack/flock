import Foundation
import Observation

public struct PinID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> PinID { PinID(rawValue: UUID().uuidString) }
}

/// Where a pin is drawn: in the rail's PINNED, or as a title-bar icon whose
/// workspace no other list shows.
public enum PinPlacement: String, Codable, Sendable {
    case rail
    case topBar
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
    public var placement: PinPlacement = .rail
    /// The cswap account Claude launches as here; nil for the current login.
    public var claudeAccount: ClaudeAccountRef?

    public var identityKey: String { "pin:\(id.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case id, name, folder, workspace, syncedLabel, confirmed, placement, claudeAccount
    }

    public init(
        id: PinID, name: String, folder: String, workspace: WorkspaceID?, syncedLabel: String?, confirmed: Bool,
        placement: PinPlacement = .rail, claudeAccount: ClaudeAccountRef? = nil
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.workspace = workspace
        self.syncedLabel = syncedLabel
        self.confirmed = confirmed
        self.placement = placement
        self.claudeAccount = claudeAccount
    }

    /// Pins stored before placement existed decode as rail pins.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PinID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        folder = try container.decode(String.self, forKey: .folder)
        workspace = try container.decodeIfPresent(WorkspaceID.self, forKey: .workspace)
        syncedLabel = try container.decodeIfPresent(String.self, forKey: .syncedLabel)
        confirmed = try container.decode(Bool.self, forKey: .confirmed)
        placement = try container.decodeIfPresent(PinPlacement.self, forKey: .placement) ?? .rail
        claudeAccount = (try? container.decodeIfPresent(ClaudeAccountRef.self, forKey: .claudeAccount))
            ?? (try? container.decodeIfPresent(String.self, forKey: .claudeAccount))
                .flatMap { $0.map { ClaudeAccountRef(email: $0, organizationUuid: nil) } }
    }
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

/// A new pin's question: where it should open, with the folders worth
/// offering, the likeliest first.
public struct PinFolderAsk: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public enum Reason: Equatable, Sendable { case shellNow, shellLastSeen, shellStarted }
        public let folder: String
        public let reason: Reason
    }

    public let pin: PinID
    public let choices: [Choice]
}

public enum PinFolders {
    /// The folder of the first pane of the workspace's first tab, as it is:
    /// never widened to its repo, since one repo can hold many places.
    public static func firstPane(of workspace: WorkspaceID, in model: SessionModel) -> String? {
        firstPaneID(of: workspace, in: model).flatMap { model.panes[$0] }.map { $0.foregroundCwd ?? $0.cwd }
    }

    /// The pane `firstPane` reads its folder from.
    public static func firstPaneID(of workspace: WorkspaceID, in model: SessionModel) -> PaneID? {
        guard let tab = model.tabs[workspace]?.first else { return nil }
        let inLayout = (model.layouts[tab.tabID]?.panes ?? []).lazy.compactMap { model.panes[$0.paneID] }.first
        let pane = inLayout ?? model.panes.values
            .filter { $0.tabID == tab.tabID }
            .min { $0.paneID.rawValue < $1.paneID.rawValue }
        return pane?.paneID
    }
}

@MainActor
@Observable
public final class PinnedWorkspaceStore {
    public static let defaultsKey = "flock.pinnedWorkspaces"

    /// Holds the first blob a person's change replaced because it could not
    /// be read; a later replacement never overwrites it.
    public static let unreadableKey = "flock.pinnedWorkspaces.unreadable"

    public static let storedVersion = 1

    public private(set) var pins: [PinnedWorkspace]

    @ObservationIgnored private let userDefaults: UserDefaults?
    /// Set while the stored pins could not be read, so an older build that
    /// merely runs never writes over a newer build's pins. Only a change the
    /// person makes to the pins writes over them.
    @ObservationIgnored private var keepsStoredData = false

    private struct Stored: Codable {
        var version: Int
        var pins: [PinnedWorkspace]
    }

    private struct StoredVersion: Decodable {
        var version: Int
    }

    /// nil keeps the pins in memory only.
    public init(userDefaults: UserDefaults?) {
        self.userDefaults = userDefaults
        guard let data = userDefaults?.data(forKey: Self.defaultsKey) else {
            pins = []
            return
        }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(StoredVersion.self, from: data).version, version <= Self.storedVersion,
              let stored = try? decoder.decode(Stored.self, from: data) else {
            pins = []
            keepsStoredData = true
            return
        }
        // An unconfirmed link spans a create's reply and the next snapshot,
        // never a relaunch. A stored one is still an id herdr issued, so the
        // next update keeps it or empties the pin like any confirmed link.
        pins = stored.pins.map { pin in
            var pin = pin
            if pin.workspace != nil { pin.confirmed = true }
            return pin
        }
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

    public func pins(in placement: PinPlacement) -> [PinnedWorkspace] {
        pins.filter { $0.placement == placement }
    }

    @discardableResult
    public func add(
        workspace: WorkspaceID, name: String, folder: String, at index: Int?, placement: PinPlacement = .rail
    ) -> PinnedWorkspace? {
        guard pin(linkedTo: workspace) == nil, !isNameTaken(name, except: nil) else { return nil }
        let pin = PinnedWorkspace(
            id: .make(), name: name, folder: folder, workspace: workspace, syncedLabel: name, confirmed: true,
            placement: placement
        )
        pins.append(pin)
        if let index { place(pin.id, in: placement, at: index, saving: false) }
        save()
        return self.pin(pin.id)
    }

    public func remove(_ id: PinID) {
        pins.removeAll { $0.id == id }
        save()
    }

    /// `index` counts the pins of this one's placement as drawn, the moving
    /// one included.
    public func move(_ id: PinID, toInsertIndex index: Int) {
        guard let current = pin(id) else { return }
        place(id, in: current.placement, at: index)
    }

    /// `index` counts the destination's pins as drawn; nil puts it last.
    public func setPlacement(_ id: PinID, to placement: PinPlacement, at index: Int?) {
        place(id, in: placement, at: index)
    }

    private func place(_ id: PinID, in placement: PinPlacement, at index: Int?, saving: Bool = true) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        let ownSlot = pins[from].placement == placement
            ? pins.indices.filter { pins[$0].placement == placement }.firstIndex(of: from)
            : nil
        var next = pins
        var moving = next.remove(at: from)
        moving.placement = placement
        let peers = next.indices.filter { next[$0].placement == placement }
        var target = index ?? peers.count
        if let ownSlot, target > ownSlot { target -= 1 }
        target = min(max(target, 0), peers.count)
        let position = target < peers.count ? peers[target] : (peers.last.map { $0 + 1 } ?? next.count)
        next.insert(moving, at: position)
        guard next != pins else { return }
        pins = next
        if saving { save() }
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

    public func setClaudeAccount(_ id: PinID, to account: ClaudeAccountRef?) {
        guard let index = pins.firstIndex(where: { $0.id == id }), pins[index].claudeAccount != account else { return }
        pins[index].claudeAccount = account
        save()
    }

    /// Links from a create's reply, before any snapshot carries the workspace.
    /// The reply's id outranks a link by name: a pin that adopted the new
    /// workspace from an event that beat the reply is emptied again.
    public func link(_ id: PinID, to workspace: WorkspaceID) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        var next = pins
        for other in next.indices where other != index && next[other].workspace == workspace {
            next[other].workspace = nil
            next[other].syncedLabel = nil
            next[other].confirmed = false
        }
        next[index].workspace = workspace
        next[index].syncedLabel = nil
        next[index].confirmed = false
        pins = next
        save(byPerson: false)
    }

    /// Keeps links that herdr still reports (names following its renames),
    /// empties pins whose workspace herdr no longer reports, then lets each
    /// empty pin adopt the first unlinked `eligible` workspace with its name.
    /// A link herdr has never reported is kept only while its pin is in
    /// `reopening`: the gap between a create's reply and the snapshot that
    /// carries the workspace.
    public func reconcile(
        with model: SessionModel, reopening: Set<PinID> = [], eligible: (WorkspaceRecord) -> Bool
    ) {
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
            } else if next[index].confirmed || !reopening.contains(next[index].id) {
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
        save(byPerson: false)
    }

    private func save(byPerson: Bool = true) {
        guard let userDefaults else { return }
        if byPerson, keepsStoredData {
            keepsStoredData = false
            if userDefaults.data(forKey: Self.unreadableKey) == nil,
               let original = userDefaults.data(forKey: Self.defaultsKey) {
                userDefaults.set(original, forKey: Self.unreadableKey)
            }
        }
        guard !keepsStoredData else { return }
        let data = try? JSONEncoder().encode(Stored(version: Self.storedVersion, pins: pins))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
