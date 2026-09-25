import Darwin
import Foundation

/// Starts herdr's headless server the way herdr's own client does: `herdr
/// server` in a session of its own, stdio on /dev/null, so it outlives flock
/// and belongs to no terminal.
enum HerdrServerLauncher {
    enum Failure: Error, Equatable {
        case notFound
        case spawn(Int32)
    }

    /// flock's child environment minus `RT_BATCH`: every pane's shell
    /// inherits the server's, and rt would run non-interactive in all of them.
    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "RT_BATCH")
        return environment
    }

    static func start() -> Result<Void, Failure> {
        guard let binary = ToolPath.resolve("herdr") else { return .failure(.notFound) }
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
        let argv = [binary, "server"]
        let envp = environment(from: ToolPath.childEnvironment()).map { "\($0.key)=\($0.value)" }
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
