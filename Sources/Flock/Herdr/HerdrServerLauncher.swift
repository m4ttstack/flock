import Darwin
import FlockCore
import Foundation

/// Starts herdr's headless server the way herdr's own client does: `herdr
/// server` in a session of its own, stdio on /dev/null, so it outlives flock
/// and belongs to no terminal.
enum HerdrServerLauncher {
    enum Failure: Error, Equatable {
        case notFound
        case spawn(Int32)
    }

    enum Target: Equatable {
        case defaultServer
        case named(String)
        case overrideSocket(String)
    }

    /// flock's child environment minus `RT_BATCH`: every pane's shell
    /// inherits the server's, and rt would run non-interactive in all of them.
    /// `HERDR_MACOS_SERVER_CONTEXT=user` is what herdr's own client sets: setsid
    /// alone leaves the server in flock's Mach bootstrap context. herdr removes
    /// the variable at startup, so panes never see it. The inherited
    /// `HERDR_SOCKET_PATH` is the current session's, which a default or named
    /// server must not bind; only an override socket sets it.
    static func environment(from base: [String: String], target: Target) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "RT_BATCH")
        environment["HERDR_MACOS_SERVER_CONTEXT"] = "user"
        switch target {
        case .defaultServer, .named: environment.removeValue(forKey: "HERDR_SOCKET_PATH")
        case .overrideSocket(let path): environment["HERDR_SOCKET_PATH"] = path
        }
        return environment
    }

    /// An invalid session name, or a sessions directory that cannot be made,
    /// comes back as `.spawn` with an errno: herdr is not run for either.
    static func start(_ target: Target) -> Result<Void, Failure> {
        guard let binary = ToolPath.resolve("herdr") else { return .failure(.notFound) }
        var arguments = ["server"]
        if case .named(let name) = target {
            guard HerdrServerAddress.isValidSessionName(name) else { return .failure(.spawn(EINVAL)) }
            let directory = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/herdr/sessions/\(name)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                return .failure(.spawn(Int32(underlying?.code ?? Int(EIO))))
            }
            arguments = ["--session", name, "server"]
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        // Where herdr opens its first workspace; an app launched from the
        // Dock runs in /.
        posix_spawn_file_actions_addchdir_np(&actions, NSHomeDirectory())
        let argv = [binary] + arguments
        let envp = environment(from: ToolPath.childEnvironment(), target: target).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&pid, binary, &actions, &attributes, argvPointers, envPointers)
            }
        }
        return status == 0 ? .success(()) : .failure(.spawn(status))
    }

    private static func withCStrings<Result>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
