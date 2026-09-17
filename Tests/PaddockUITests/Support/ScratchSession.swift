import Darwin
import Foundation

/// The ids `Support/bin/seed-layout.sh` produces: one workspace, `tabA`
/// holding `p1` and `p2` side by side, `tabB` holding `p3` alone.
struct SeedIDs {
    let ws: String
    let tabA: String
    let tabB: String
    let p1: String
    let p2: String
    let p3: String
}

struct ScratchSessionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The test bundle's end of the e2e harness: a ground-truth channel into the
/// herdr session `Scripts/e2e.sh` created for this run, independent of the app
/// under test.
///
/// Nothing here touches herdr's socket directly, and not by preference. Xcode
/// hosts every macOS UI-testing bundle in a `-Runner.app` it sandboxes
/// unconditionally, and that sandbox denies `connect()` on any unix socket
/// outside the container: `nc -U` exits 1 with no message and a native
/// AF_UNIX connect returns EPERM, whether the caller is this bundle or a
/// process it spawned. Outbound TCP to loopback IS permitted, so every request
/// below goes to `Support/bin/e2e-bridge.py`, which the wrapper runs outside
/// the sandbox, and which forwards to herdr and performs the two session
/// operations no sandboxed process can.
///
/// One session serves a whole `xcodebuild test` invocation, so a case that
/// leaves the layout changed would hand the next case a dirty world. Call
/// `reseed()` in `setUpWithError` to start from the canonical seed; herdr
/// numbers a fresh session's ids from one, so `seedIDs()` stays correct across
/// a reseed.
final class ScratchSession {
    let socketPath: String
    private let ids: SeedIDs
    private let bridgePort: UInt16
    private let bridgeToken: String

    private init(socketPath: String, ids: SeedIDs, bridgePort: UInt16, bridgeToken: String) {
        self.socketPath = socketPath
        self.ids = ids
        self.bridgePort = bridgePort
        self.bridgeToken = bridgeToken
    }

    static func attachFromEnvironment() throws -> ScratchSession {
        let environment = ProcessInfo.processInfo.environment
        func present(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }
        guard let socketPath = present("PADDOCK_SOCKET") else {
            throw ScratchSessionError(
                "PADDOCK_SOCKET is unset. Run this suite through Scripts/e2e.sh: xcodebuild on its own boots no herdr session."
            )
        }
        guard let rawPort = present("PADDOCK_BRIDGE_PORT"), let port = UInt16(rawPort) else {
            throw ScratchSessionError(
                "PADDOCK_BRIDGE_PORT is unset or not a port: \(present("PADDOCK_BRIDGE_PORT") ?? "<unset>")"
            )
        }
        guard let token = present("PADDOCK_BRIDGE_TOKEN") else {
            throw ScratchSessionError("PADDOCK_BRIDGE_TOKEN is unset; the bridge refuses every request without it")
        }
        guard let seed = present("PADDOCK_SEED_IDS"), let data = seed.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw ScratchSessionError(
                "PADDOCK_SEED_IDS is not a JSON object of ids: \(present("PADDOCK_SEED_IDS") ?? "<unset>")"
            )
        }
        func id(_ key: String) throws -> String {
            guard let value = map[key], !value.isEmpty else {
                throw ScratchSessionError("PADDOCK_SEED_IDS carries no \(key): \(map)")
            }
            return value
        }
        return ScratchSession(
            socketPath: socketPath,
            ids: SeedIDs(
                ws: try id("ws"), tabA: try id("tabA"), tabB: try id("tabB"),
                p1: try id("p1"), p2: try id("p2"), p3: try id("p3")
            ),
            bridgePort: port,
            bridgeToken: token
        )
    }

    func seedIDs() -> SeedIDs { ids }

    func snapshot() throws -> HerdrSnapshotJSON {
        let response = try request(#"{"id":"e2e-snapshot","method":"session.snapshot","params":{}}"#)
        guard let result = response["result"] as? [String: Any],
              let snapshot = result["snapshot"] as? [String: Any] else {
            throw ScratchSessionError("session.snapshot carried no snapshot: \(response)")
        }
        return HerdrSnapshotJSON(snapshot)
    }

    /// Polls until the session says what the caller is waiting for, and
    /// returns that snapshot. A gesture reaches herdr through an RPC and comes
    /// back through an event, so nothing a drop does is visible in the instant
    /// the drop finished; reading once would test the timing rather than the
    /// drop.
    ///
    /// A timeout names what was expected AND what herdr was actually holding:
    /// a case authored against a layout that never arrived is otherwise
    /// indistinguishable from a gesture that missed its target.
    func snapshot(
        waitingFor expectation: String, timeout: TimeInterval = 20, until condition: (HerdrSnapshotJSON) -> Bool
    ) throws -> HerdrSnapshotJSON {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: HerdrSnapshotJSON?
        while Date() < deadline {
            let current = try snapshot()
            latest = current
            if condition(current) { return current }
            usleep(100_000)
        }
        throw ScratchSessionError(
            "timed out after \(timeout)s waiting for \(expectation). herdr holds: "
                + (latest?.outline() ?? "<no snapshot answered>")
        )
    }

    /// Changes the world the app is mirroring without going through the app,
    /// so a case can assert on what the app does with a change it did not
    /// make. Throws on a herdr error response rather than letting a rejected
    /// request read as a mutation that landed.
    func mutate(_ requestLine: String) throws {
        _ = try request(requestLine)
    }

    /// Stops only the server process and brings it back on the same session
    /// directory, so the state it was holding is what it comes back to.
    func restartServer() throws {
        try control("restart-server")
        try awaitLiveServer()
    }

    /// Destroys the session and rebuilds it from `seed-layout.sh`, which is
    /// how a case gets a pristine layout: the ids are the same afterward
    /// because herdr numbers a new session's workspaces, tabs and panes from
    /// one.
    func reseed() throws {
        try control("reseed-session")
        try awaitLiveServer()
        try waitUntil(timeout: 20, "the reseeded session to carry the seed layout") {
            guard let snapshot = try? self.snapshot() else { return false }
            return snapshot.paneIDs(inTab: self.ids.tabA) == [self.ids.p1, self.ids.p2]
                && snapshot.paneIDs(inTab: self.ids.tabB) == [self.ids.p3]
        }
    }

    /// Teardown belongs to `Scripts/e2e.sh`'s trap, which owns the server this
    /// object only talks to. Present so a case reads the same as the plan's
    /// exemplar.
    func stop() {}

    // MARK: - Bridge transport

    @discardableResult
    private func request(_ requestLine: String) throws -> [String: Any] {
        let reply = try bridge("herdr " + requestLine.trimmingCharacters(in: .newlines))
        guard let data = reply.data(using: .utf8),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ScratchSessionError("herdr answered \(requestLine) with something that is not a JSON object: \(reply)")
        }
        if let error = response["error"] {
            throw ScratchSessionError("herdr rejected \(requestLine): \(error)")
        }
        return response
    }

    private func control(_ verb: String) throws {
        let reply = try bridge("control " + verb)
        guard let data = reply.data(using: .utf8),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ScratchSessionError("the bridge answered \(verb) with something that is not a JSON object: \(reply)")
        }
        if let error = response["error"] {
            throw ScratchSessionError("the bridge could not \(verb): \(error)")
        }
    }

    /// A control verb takes the server down and brings it back, so the session
    /// is usable again only once a request actually answers.
    private func awaitLiveServer() throws {
        try waitUntil(timeout: 30, "the scratch server to answer again") {
            (try? self.snapshot()) != nil
        }
    }

    private func waitUntil(timeout: TimeInterval, _ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(25_000)
        }
        throw ScratchSessionError("timed out after \(timeout)s waiting for \(what)")
    }

    /// Sends a line to the bridge verbatim, token included. Only the harness's
    /// own coverage of the token needs this; every other caller goes through
    /// `request` or `control`, which prepend it.
    func sendRawBridgeLine(_ line: String) throws -> String {
        try send(line)
    }

    private func bridge(_ line: String) throws -> String {
        try send(bridgeToken + " " + line)
    }

    /// One request per connection, one line each way. Every failure says which
    /// half it came from: reaching the bridge at all, or what the bridge said.
    private func send(_ line: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ScratchSessionError("could not make a socket for the e2e bridge: errno \(errno)")
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = bridgePort.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw ScratchSessionError(
                "could not reach the e2e bridge on 127.0.0.1:\(bridgePort): errno \(errno). Scripts/e2e.sh runs it; it is not running."
            )
        }

        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var outgoing = Array((line + "\n").utf8)
        var sent = 0
        while sent < outgoing.count {
            let written = outgoing.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            }
            guard written > 0 else {
                throw ScratchSessionError("the e2e bridge closed while \(line.prefix(60)) was being sent: errno \(errno)")
            }
            sent += written
        }

        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !incoming.contains(UInt8(ascii: "\n")) {
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read < 0 {
                throw ScratchSessionError("the e2e bridge failed mid-reply to \(line.prefix(60)): errno \(errno)")
            }
            if read == 0 { break }
            incoming.append(contentsOf: buffer[0..<read])
        }
        let reply = String(decoding: incoming, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard !reply.isEmpty else {
            throw ScratchSessionError("the e2e bridge answered \(line.prefix(60)) with nothing")
        }
        return reply
    }
}
