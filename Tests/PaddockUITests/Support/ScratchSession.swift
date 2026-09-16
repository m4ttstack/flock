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
/// herdr session `Scripts/e2e.sh` created for this run, independent of the
/// app under test.
///
/// Attach-only, and not by preference. Xcode hosts every macOS UI-testing
/// bundle in a `-Runner.app` it sandboxes unconditionally, and that sandbox
/// refuses both a listening socket and any write outside the container, so
/// this side can neither start herdr nor drop a file for anything else to
/// find. Connecting to a socket that already exists is permitted, which is
/// what every method here does: the herdr socket for reads and mutations, and
/// `Scripts/e2e.sh`'s control socket for the two operations only an
/// unsandboxed process can perform.
///
/// One session serves a whole `xcodebuild test` invocation, so a case that
/// leaves the layout changed would hand the next case a dirty world. Call
/// `reseed()` in `setUpWithError` to start from the canonical seed; herdr
/// numbers a fresh session's ids from one, so `seedIDs()` stays correct
/// across a reseed.
final class ScratchSession {
    let socketPath: String
    private let ids: SeedIDs
    private let controlSocketPath: String?

    private init(socketPath: String, ids: SeedIDs, controlSocketPath: String?) {
        self.socketPath = socketPath
        self.ids = ids
        self.controlSocketPath = controlSocketPath
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
            controlSocketPath: present("PADDOCK_CONTROL_SOCKET")
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
        try awaitServerCycle()
    }

    /// Destroys the session and rebuilds it from `seed-layout.sh`, which is
    /// how a case gets a pristine layout: the ids are the same afterward
    /// because herdr numbers a new session's workspaces, tabs and panes from
    /// one.
    func reseed() throws {
        try control("reseed-session")
        try awaitServerCycle()
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

    // MARK: - herdr and control transport

    @discardableResult
    private func request(_ requestLine: String) throws -> [String: Any] {
        let line = requestLine.hasSuffix("\n") ? requestLine : requestLine + "\n"
        let result = Self.run("/usr/bin/nc", ["-U", "-w", "5", socketPath], stdin: line)
        guard let first = result.stdout.split(separator: "\n").first,
              let data = first.data(using: .utf8),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ScratchSessionError(
                "no parseable herdr response to \(requestLine): stdout=\(result.stdout) stderr=\(result.stderr)"
            )
        }
        if let error = response["error"] {
            throw ScratchSessionError("herdr rejected \(requestLine): \(error)")
        }
        return response
    }

    /// The wrapper's listener is one-shot and re-arms between requests, so a
    /// connection that lands in that gap is a miss to retry, not a failure.
    private func control(_ verb: String) throws {
        guard let controlSocketPath else {
            throw ScratchSessionError(
                "PADDOCK_CONTROL_SOCKET is unset: only Scripts/e2e.sh can start or stop this session's server."
            )
        }
        let deadline = Date().addingTimeInterval(15)
        var lastFailure = ""
        while Date() < deadline {
            let result = Self.run("/usr/bin/nc", ["-U", "-w", "5", controlSocketPath], stdin: verb + "\n")
            if result.status == 0 { return }
            lastFailure = result.stderr.isEmpty ? "exit \(result.status)" : result.stderr
            usleep(50_000)
        }
        throw ScratchSessionError("could not reach the e2e control socket at \(controlSocketPath): \(lastFailure)")
    }

    /// Both control verbs take the server down and bring it back, so both are
    /// finished only once the socket has gone AND answers again. Waiting for
    /// the answer alone would pass instantly against the server that is about
    /// to be stopped.
    private func awaitServerCycle() throws {
        try waitUntil(timeout: 15, "the scratch server to go down") {
            !FileManager.default.fileExists(atPath: self.socketPath)
        }
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

    private struct CommandResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Every executable is named by absolute path, so nothing here depends on
    /// the curated PATH the test runner is handed.
    private static func run(_ path: String, _ arguments: [String], stdin: String? = nil) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        let inPipe = Pipe()
        task.standardInput = inPipe
        do {
            try task.run()
        } catch {
            return CommandResult(stdout: "", stderr: "\(path) did not run: \(error)", status: -1)
        }
        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return CommandResult(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            status: task.terminationStatus
        )
    }
}
