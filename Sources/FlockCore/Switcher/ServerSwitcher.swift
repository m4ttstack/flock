import Foundation

public typealias ServerSwitcher = RecentsSwitcher<ServerID>

/// A herdr server's socket path, normalized, typed for `RecentsSwitcher`.
public struct ServerID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(socketPath: String, home: String) {
        rawValue = HerdrServerAddress.normalize(socketPath, home: home)
    }
}

extension RecentsSwitcher where ID == ServerID {
    public static var defaultsKey: String { "flock.serverRecents" }

    /// Handed the profile's preferences suite, so each profile keeps the
    /// servers used in it, and a deleted profile's list goes with its suite.
    public convenience init(userDefaults: UserDefaults) {
        self.init(defaultsKey: Self.defaultsKey, userDefaults: userDefaults)
    }

    /// The servers Settings' Server menu lists, in its order, plus the
    /// current one when herdr does not list it (a custom socket), since
    /// `begin` reads the first row as where the switch started. None while
    /// the list is unread or the window cannot change server.
    public static func candidates(
        _ entries: [HerdrSessionEntry]?, currentSocket: String, home: String, canChangeServer: Bool
    ) -> [ServerID] {
        guard canChangeServer, let entries else { return [] }
        var ids: [ServerID] = []
        for entry in entries {
            let id = ServerID(socketPath: entry.socketPath, home: home)
            if !ids.contains(id) { ids.append(id) }
        }
        let current = ServerID(socketPath: currentSocket, home: home)
        if !ids.contains(current) { ids.append(current) }
        return ids
    }

    /// Called for every change of the current server, whatever made it, so
    /// the first tap goes back to the one before.
    public func note(currentSocket: String, home: String) {
        note(ServerID(socketPath: currentSocket, home: home))
    }
}

/// One row of ⌥`'s panel: named as Settings' Server menu names it.
public struct ServerSwitcherRow: Equatable, Sendable {
    public let label: String
    /// Nil for a socket herdr does not list.
    public let status: String?
    public let isCurrent: Bool

    public init(label: String, status: String?, isCurrent: Bool) {
        self.label = label
        self.status = status
        self.isCurrent = isCurrent
    }

    /// Falls back to the address's label for a server the list no longer
    /// carries, so a row already on screen keeps drawing while a refresh
    /// lands.
    public static func make(
        _ id: ServerID, entries: [HerdrSessionEntry], currentSocket: String, home: String
    ) -> ServerSwitcherRow {
        let entry = entries.first { ServerID(socketPath: $0.socketPath, home: home) == id }
        return ServerSwitcherRow(
            label: entry?.name ?? HerdrServerAddress(socketPath: id.rawValue, home: home).label,
            status: entry?.statusLabel,
            isCurrent: id == ServerID(socketPath: currentSocket, home: home)
        )
    }
}
