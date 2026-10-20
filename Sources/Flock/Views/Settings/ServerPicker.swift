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
    private(set) var isBusy = false
    let isLocked: Bool

    @ObservationIgnored private let list: () async -> [HerdrSessionEntry]?
    @ObservationIgnored private let start: (String) -> Result<Void, HerdrServerLauncher.Failure>
    @ObservationIgnored private let chooseSocket: (String?) async -> Bool
    @ObservationIgnored private let currentSocket: () -> String
    @ObservationIgnored private let home: String

    init(
        list: @escaping () async -> [HerdrSessionEntry]?,
        start: @escaping (String) -> Result<Void, HerdrServerLauncher.Failure>,
        choose: @escaping (String?) async -> Bool,
        currentSocket: @escaping () -> String,
        isLocked: Bool,
        home: String
    ) {
        self.list = list
        self.start = start
        self.chooseSocket = choose
        self.currentSocket = currentSocket
        self.isLocked = isLocked
        self.home = home
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

    /// A failed listing keeps the entries already shown.
    func refresh() async {
        if let listed = await list() { entries = listed }
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
            let address = HerdrServerAddress(socketPath: trimmed, home: home)
            _ = await chooseSocket(address == .defaultServer ? nil : address.socketPath(home: home))
        }
    }

    /// A request made while another is in flight is dropped, so a double
    /// click cannot start the same server twice.
    private func whileIdle(_ body: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        await body()
        isBusy = false
    }

    private func launch(name: String) -> String? {
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
