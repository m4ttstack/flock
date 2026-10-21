import FlockCore
import Foundation
import Observation

/// The current profile's herdr server, as Settings offers it. Every change
/// goes through `choose`, so the session controller stays the only writer of
/// the profile's socket.
@MainActor
@Observable
final class ServerPicker {
    private(set) var entries: [HerdrSessionEntry] = []
    private(set) var failure: String?
    /// True when `failure` came from stopping or deleting a listed server,
    /// so it shows under that list rather than under the Server row.
    private(set) var failureIsFromServerList = false
    private(set) var isBusy = false
    /// Which other Flock holds each listed socket, as of the last refresh.
    private(set) var holders: [String: String] = [:]
    let isLocked: Bool

    @ObservationIgnored private let list: () async -> [HerdrSessionEntry]?
    @ObservationIgnored private let start: (String) -> Result<Void, HerdrServerLauncher.Failure>
    @ObservationIgnored private let chooseSocket: (String?) async -> Bool
    @ObservationIgnored private let currentSocket: () -> String
    @ObservationIgnored private let switchingTo: () -> String?
    @ObservationIgnored private let heldBy: @MainActor (String) -> String?
    @ObservationIgnored private let stop: (String) async -> Result<Void, HerdrSessionControl.Failure>
    @ObservationIgnored private let delete: (String) async -> Result<Void, HerdrSessionControl.Failure>
    @ObservationIgnored let home: String

    init(
        list: @escaping () async -> [HerdrSessionEntry]?,
        start: @escaping (String) -> Result<Void, HerdrServerLauncher.Failure>,
        choose: @escaping (String?) async -> Bool,
        currentSocket: @escaping () -> String,
        isLocked: Bool,
        home: String,
        heldBy: @escaping @MainActor (String) -> String? = { _ in nil },
        switchingTo: @escaping () -> String? = { nil },
        stop: @escaping (String) async -> Result<Void, HerdrSessionControl.Failure> = { _ in .failure(.notFound) },
        delete: @escaping (String) async -> Result<Void, HerdrSessionControl.Failure> = { _ in .failure(.notFound) }
    ) {
        self.list = list
        self.start = start
        self.chooseSocket = choose
        self.currentSocket = currentSocket
        self.isLocked = isLocked
        self.home = home
        self.heldBy = heldBy
        self.switchingTo = switchingTo
        self.stop = stop
        self.delete = delete
    }

    /// What the Servers list offers for `entry`, from the last refresh's
    /// holders.
    func action(for entry: HerdrSessionEntry) -> HerdrServerAction {
        HerdrServerActions.action(for: entry, currentSocket: currentSocket(), home: home, heldBy: { holders[$0] })
    }

    var currentLabel: String {
        HerdrServerAddress(socketPath: currentSocket(), home: home).label
    }

    var lockedNote: String? {
        isLocked ? "Set by HERDR_SOCKET_PATH: \(currentSocket())" : nil
    }

    func isCurrent(_ entry: HerdrSessionEntry) -> Bool {
        HerdrServerAddress.normalize(entry.socketPath, home: home) == HerdrServerAddress.normalize(currentSocket(), home: home)
    }

    /// A failed listing keeps the entries already shown and returns false.
    @discardableResult
    func refresh() async -> Bool {
        let listed = await list()
        if let listed { entries = listed }
        var held: [String: String] = [:]
        for entry in entries {
            if let app = heldBy(entry.socketPath) { held[entry.socketPath] = app }
        }
        holders = held
        return listed != nil
    }

    func choose(_ entry: HerdrSessionEntry) async {
        await whileIdle { _ = await chooseSocket(entry.isDefault ? nil : entry.socketPath) }
    }

    func startServer(name: String) async -> String? {
        var socket: String?
        await whileIdle { socket = launch(name: name) }
        return socket
    }

    func startNew(name: String) async {
        await whileIdle {
            guard let socket = launch(name: name) else { return }
            _ = await chooseSocket(socket)
        }
    }

    func chooseCustom(path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await whileIdle {
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
                failure = "Use a full path, starting with / or ~."
                return
            }
            let address = HerdrServerAddress(socketPath: trimmed, home: home)
            _ = await chooseSocket(address == .defaultServer ? nil : address.socketPath(home: home))
        }
    }

    /// Unlike the other requests, a confirmed Stop or Delete made while
    /// busy says why nothing happened: its alert has already closed.
    func stopServer(name: String) async {
        guard !refuseWhileBusy() else { return }
        await whileIdle { await control(name: name, expecting: .stop, with: stop) }
    }

    func deleteServer(name: String) async {
        guard !refuseWhileBusy() else { return }
        await whileIdle { await control(name: name, expecting: .delete, with: delete) }
    }

    private func refuseWhileBusy() -> Bool {
        guard isBusy else { return false }
        failure = "Busy switching servers. Try again in a moment."
        failureIsFromServerList = true
        return true
    }

    /// The row's action was decided when it drew; a confirmation can stay
    /// open while this Flock or another one moves onto that server, so the
    /// rule is checked again against a fresh list before herdr runs.
    private func control(
        name: String, expecting expected: HerdrServerAction,
        with run: (String) async -> Result<Void, HerdrSessionControl.Failure>
    ) async {
        if !(await refresh()) {
            failure = "Couldn't check herdr's servers, so \"\(name)\" wasn't \(expected == .stop ? "stopped" : "deleted")."
        } else if let refusal = refusal(name: name, expecting: expected) {
            failure = refusal
        } else if case .failure(let error) = await run(name) {
            failure = error.message
        }
        failureIsFromServerList = failure != nil
        await refresh()
    }

    private func refusal(name: String, expecting expected: HerdrServerAction) -> String? {
        guard let entry = entries.first(where: { $0.name == name }) else { return "\"\(name)\" isn't listed any more." }
        let verb = expected == .stop ? "stop" : "delete"
        if let target = switchingTo(),
           case .unavailable(let reason) = HerdrServerActions.action(for: entry, currentSocket: target, home: home, heldBy: heldBy) {
            return "Didn't \(verb) \"\(name)\": \(reason)."
        }
        let now = HerdrServerActions.action(for: entry, currentSocket: currentSocket(), home: home, heldBy: heldBy)
        switch now {
        case expected: return nil
        case .unavailable(let reason): return "Didn't \(verb) \"\(name)\": \(reason)."
        case .stop: return "\"\(name)\" is running again."
        case .delete: return "\"\(name)\" isn't running any more."
        }
    }

    /// A request made while another is in flight is dropped, so a double
    /// click cannot start the same server twice.
    private func whileIdle(_ body: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        failureIsFromServerList = false
        await body()
        isBusy = false
    }

    /// A name listed as running is reused, never spawned a second time.
    private func launch(name: String) -> String? {
        if let running = entries.first(where: { $0.name == name && $0.isRunning && !$0.isDefault }) {
            return running.socketPath
        }
        guard name != "default" else {
            failure = "\"default\" is herdr's own server. Pick another name."
            return nil
        }
        guard HerdrServerAddress.isValidSessionName(name) else {
            failure = "\"\(name)\" can't be a server name. Use letters, digits, \".\", \"_\" or \"-\"."
            return nil
        }
        if case .failure(let error) = start(name) {
            failure = error.message
            return nil
        }
        return HerdrServerAddress.named(name).socketPath(home: home)
    }
}
