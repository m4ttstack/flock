import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct SeedIDs {
    let ws, tabA, tabB, p1, p2, p3: String
}

/// Wraps spikes/lib/scratch-session.sh + seed-layout.sh so the UI test has
/// its own ground-truth channel into herdr, independent of the app under
/// test. This object's connections are never shared with the app: herdr's
/// api socket answers exactly one request per connection, then closes it
/// (spikes/02-socket/FINDINGS.md), so every call here opens a fresh one.
final class ScratchHerdrSession {
    let socketPath: String
    private let sessionName: String
    private let libDir: String

    private init(socketPath: String, sessionName: String, libDir: String) {
        self.socketPath = socketPath
        self.sessionName = sessionName
        self.libDir = libDir
    }

    /// NOTE (see FINDINGS.md "sandboxed test runner"): starting the scratch
    /// herdr SERVER from inside the XCUITest process itself does not work --
    /// the macOS UI test runner (`*-Runner.app`) is unconditionally App
    /// Sandboxed by Xcode's own toolchain (no project setting turns this
    /// off), and its inherited sandbox blocks bind()/listen() on a socket
    /// path outside its own container. `start` is kept for completeness and
    /// for use from an unsandboxed context (plain `swift test`, a CLI tool);
    /// the UI test itself uses `attach`, connecting to a session a plain-bash
    /// wrapper already started outside the sandbox.
    static func start(name: String) throws -> ScratchHerdrSession {
        let libDir = ScratchHerdrSession.resolveLibDir()
        let (out, err) = try ScratchHerdrSession.run("/bin/bash", ["\(libDir)/scratch-session.sh", "start", name])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw SpikeError("scratch-session.sh start did not print a socket path: stdout=\(out) stderr=\(err)")
        }
        return ScratchHerdrSession(socketPath: path, sessionName: name, libDir: libDir)
    }

    /// Attaches to a scratch session an external, unsandboxed process already
    /// started (see `start`'s note). Every subsequent call this object makes
    /// (`request`, `tabCount`) is a one-shot CLIENT connection to an existing
    /// socket file, which the sandbox's `network.client` entitlement permits
    /// even from inside the test runner -- only the initial bind/listen is
    /// the blocked operation.
    static func attach(socketPath: String, sessionName: String) -> ScratchHerdrSession {
        ScratchHerdrSession(socketPath: socketPath, sessionName: sessionName, libDir: ScratchHerdrSession.resolveLibDir())
    }

    func seedLayout() throws -> SeedIDs {
        let (out, err) = try ScratchHerdrSession.run("/bin/bash", ["\(libDir)/seed-layout.sh", socketPath])
        guard let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw SpikeError("seed-layout.sh did not print the id map: stdout=\(out) stderr=\(err)")
        }
        guard let ws = obj["ws"], let tabA = obj["tabA"], let tabB = obj["tabB"],
              let p1 = obj["p1"], let p2 = obj["p2"], let p3 = obj["p3"] else {
            throw SpikeError("seed-layout.sh id map missing keys: \(obj)")
        }
        return SeedIDs(ws: ws, tabA: tabA, tabB: tabB, p1: p1, p2: p2, p3: p3)
    }

    /// One-shot request/response over a fresh connection, via `nc -U`.
    func request(id: String, method: String, params: [String: Any]) throws -> [String: Any] {
        let obj: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let line = String(data: data, encoding: .utf8)! + "\n"
        let response = try ScratchHerdrSession.runWithStdin("/usr/bin/nc", ["-U", "-w", "2", socketPath], stdin: line)
        let firstLine = response.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? response
        guard let respData = firstLine.data(using: .utf8),
              let respObj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] else {
            throw SpikeError("unparseable herdr response: \(response)")
        }
        return respObj
    }

    /// herdr's session.snapshot returns a FLAT `tabs[]` list (each tab
    /// carrying its own `workspace_id`), not tabs nested under a workspace
    /// object -- confirmed against spikes/03-verbs/run.sh's case1, which
    /// reads `.result.snapshot.tabs[] | select(.tab_id==$t)` the same way.
    func tabCount(workspaceID: String) throws -> Int {
        let resp = try request(id: "snap-\(UUID().uuidString.prefix(8))", method: "session.snapshot", params: [:])
        guard let result = resp["result"] as? [String: Any],
              let snapshot = result["snapshot"] as? [String: Any],
              let tabs = snapshot["tabs"] as? [[String: Any]] else {
            throw SpikeError("session.snapshot missing tabs: \(resp)")
        }
        return tabs.filter { ($0["workspace_id"] as? String) == workspaceID }.count
    }

    func stop() {
        _ = try? ScratchHerdrSession.run("/bin/bash", ["\(libDir)/scratch-session.sh", "stop", sessionName])
    }

    /// #filePath resolves to this source file's absolute path on whichever
    /// machine compiled it, which is always the checkout the test is running
    /// from -- avoids hardcoding a worktree path that would go stale the
    /// moment this spike is copied or the worktree is disposed.
    private static func resolveLibDir() -> String {
        if let envDir = ProcessInfo.processInfo.environment["SPIKE_LIB_DIR"] {
            return envDir
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let spikesDir = thisFile
            .deletingLastPathComponent() // SpikeUITests
            .deletingLastPathComponent() // 05-uitest
            .deletingLastPathComponent() // spikes
        return spikesDir.appendingPathComponent("lib").path
    }

    /// The xcodebuild test-runner process does not reliably inherit the
    /// invoking shell's full PATH (herdr lives in ~/.local/bin, which is not
    /// on that curated PATH), so scratch-session.sh's `herdr` invocation
    /// silently fails to find the binary unless PATH is widened explicitly.
    ///
    /// The macOS UI test runner app (SpikeUITests-Runner.xctrunner) is App
    /// Sandboxed by Xcode's own template, unconditionally -- there is no
    /// project.yml setting that turns it off. That sandbox is inherited by
    /// every child process this bundle forks, so `$HOME` as bash sees it
    /// resolves to the sandbox container
    /// (~/Library/Containers/<bundle-id>/Data), not the real home directory,
    /// and scratch-session.sh's socket path silently ends up there instead of
    /// where a human (or `spikes/lib` used from plain bash) would expect.
    /// getpwuid(3) queries opendirectoryd directly and is NOT subject to that
    /// virtualization, so it recovers the real path; forcing HOME to it here
    /// keeps the scratch session where the rest of the harness expects it.
    private static func environmentWithWidenedPath() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/Users/matt/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extra + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            env["HOME"] = String(cString: dir)
        }
        return env
    }

    /// Returns (stdout, stderr) so callers can report the real failure
    /// reason instead of just "no output".
    private static func run(_ path: String, _ args: [String]) throws -> (String, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = environmentWithWidenedPath()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "")
    }

    private static func runWithStdin(_ path: String, _ args: [String], stdin: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = environmentWithWidenedPath()
        let inPipe = Pipe()
        let outPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = Pipe()
        try task.run()
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        task.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
