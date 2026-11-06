import Darwin
import FlockCore
import Foundation

/// The processes and files behind a machine profile: herdr's machine list,
/// the ssh calls and the local tunnel directories.
enum MachineSources {
    struct DirectoryError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) is not a private folder Flock owns." }
    }

    static let bundleTag = MachineTunnelPaths.bundleTag(for: Bundle.main.bundleIdentifier ?? "dev.mattstack.Flock")

    static func paths(for machine: HerdrMachine) -> MachineTunnelPaths {
        MachineTunnelPaths(uid: getuid(), bundleTag: bundleTag, machineID: machine.id)
    }

    @MainActor
    static func tunnel(for machine: HerdrMachine) -> MachineTunnel {
        MachineTunnel(
            machine: machine,
            paths: paths(for: machine),
            resolve: { try await resolve($0) },
            launch: { try SSHTunnelProcess(arguments: $0, environment: ToolPath.childEnvironment()) },
            probe: { await probe($0) },
            prepareDirectory: { try prepareDirectory($0) },
            removeDirectory: { removeDirectory($0) }
        )
    }

    /// Nil when herdr is missing, fails, misses the deadline or answers with
    /// something else.
    static func list() async -> [HerdrMachine]? {
        // Resolving the PATH can block on the login shell probe.
        let prepared = await Task.detached { () -> (binary: String, environment: [String: String])? in
            guard let binary = ToolPath.resolve("herdr") else { return nil }
            return (binary, ToolPath.childEnvironment())
        }.value
        guard let prepared else { return nil }
        let runner = ToolRunner(binaryPath: prepared.binary, environment: prepared.environment, deadline: .seconds(5))
        guard let result = try? await runner.run(["machine", "list", "--json"]), result.exitCode == 0 else { return nil }
        return HerdrMachineList.parse(result.stdout)
    }

    /// The remote server's API socket for the machine's session.
    static func resolve(_ machine: HerdrMachine) async throws -> String {
        let environment = await Task.detached { ToolPath.childEnvironment() }.value
        let runner = ToolRunner(binaryPath: SSHTunnelProcess.sshPath, environment: environment, deadline: .seconds(10))
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runner.runCapturingStderr(MachineSSH.resolveArguments(target: machine.target))
        } catch ToolRunner.Failure.timedOut {
            throw MachineResolveError.failed("Timed out.")
        } catch ToolRunner.Failure.didNotStart(let message) {
            throw MachineResolveError.failed(message)
        }
        guard result.exitCode == 0 else {
            throw MachineResolveError.failed(MachineSSH.lastLine(of: result.stderr) ?? "ssh exited with status \(result.exitCode).")
        }
        guard let entries = HerdrSessionList.parse(result.stdout) else {
            throw MachineResolveError.failed("Unexpected reply from herdr on \(machine.label).")
        }
        return try MachineSSH.remoteAPISocket(from: entries, session: machine.session)
    }

    /// Whether the local socket accepts a connection within a second.
    static func probe(_ socketPath: String) async -> Bool {
        let (answers, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        Task.detached {
            if let socket = try? await LineSocket(path: socketPath) {
                await socket.close()
                continuation.yield(true)
            } else {
                continuation.yield(false)
            }
            continuation.finish()
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(1))
            continuation.yield(false)
            continuation.finish()
        }
        defer { deadline.cancel() }
        for await answer in answers {
            return answer
        }
        return false
    }

    /// Creates `/tmp/flock-<uid>` and the tunnel directory, each mode 0700 and
    /// owned by this user. Anyone can create a directory under /tmp, and one
    /// that already exists keeps the owner and mode it was made with.
    static func prepareDirectory(_ directory: String) throws {
        try makePrivateDirectory((directory as NSString).deletingLastPathComponent)
        try makePrivateDirectory(directory)
    }

    static func removeDirectory(_ directory: String) {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Clears tunnel directories a crashed run of this app left behind. Runs
    /// before any tunnel starts, since it cannot tell a live one from a stale one.
    static func sweepStaleDirectories(bundleTag: String) {
        let root = MachineTunnelPaths.root(uid: getuid())
        guard isPrivateDirectory(root),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for entry in MachineTunnelPaths.staleEntries(entries, bundleTag: bundleTag) {
            let path = "\(root)/\(entry)"
            if isPrivateDirectory(path) { removeDirectory(path) }
        }
    }

    private static func makePrivateDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard isPrivateDirectory(path) else { throw DirectoryError(path: path) }
        guard chmod(path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// A real directory, not a link to one, owned by this user.
    private static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
}
