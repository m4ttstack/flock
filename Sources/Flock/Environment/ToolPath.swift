import Darwin
import FlockCore
import Foundation
import os

/// The PATH flock resolves the tools it runs against -- `herdr` for every
/// pane's bridge, the agent CLIs the launcher offers -- merged once for the
/// life of the process.
///
/// Started from a terminal, flock inherits the PATH that terminal's shell
/// built out of the user's profile, and every tool is where it expects. Started
/// from Finder, or from the tray's launchd job (which is the deployment), it
/// inherits launchd's instead: `launchctl getenv PATH` is unset on this
/// machine, so that is the bare system default, and `~/.local/bin` -- where
/// herdr and both agent CLIs live -- is not on it. Asking the login shell is
/// what closes the gap, and it answers for whatever the user has actually
/// installed rather than for a list of directories flock would have to keep
/// up to date.
///
/// `UserPath.merged` owns what happens to the answer; this type owns only the
/// asking.
enum ToolPath {
    static let log = Logger(subsystem: "dev.mattstack.flock", category: "path")

    /// Long enough that only a wedged shell reaches it rather than a slow one
    /// (a login `zsh -lc` answers in about 20ms on this machine), short enough
    /// to bound a reader that arrives before `warm` has finished.
    private static let probeTimeout: TimeInterval = 2

    /// Resolved on first read and then fixed for the process's life. Every
    /// reader after the first gets the stored string; a reader that beats
    /// `warm` blocks until the probe answers or `probeTimeout` ends it.
    static let resolved: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let shell = loginShell()
        let answer = probeLoginShell(shell)
        let merged = UserPath.merged(inherited: inherited, loginShell: answer)
        log.log(
            "tool path shell=\(shell, privacy: .public) answered=\(answer != nil) inherited=\(UserPath.entries(inherited).count) merged=\(UserPath.entries(merged).count)"
        )
        return merged
    }()

    /// Where `name` resolves on that PATH, or nil. The directory scan is fresh
    /// per call, so a tool installed mid-session is found without a relaunch;
    /// only the PATH it is looked for on is the cached one.
    static func resolve(_ name: String) -> String? {
        UserPath.resolve(name, on: resolved)
    }

    /// Resolves off the main thread, at startup, and records where each of
    /// `tools` landed. A tool that resolves to nothing is a pane that will not
    /// start or a button that will not render, and neither of those says
    /// anything about PATH on its own.
    static func warm(reporting tools: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = tools.map { "\($0)=\(resolve($0) ?? "not found")" }.joined(separator: " ")
            log.log("tool path \(report, privacy: .public)")
        }
    }

    /// The login shell from the password database rather than from `SHELL`:
    /// the environment a launchd job hands an app is not guaranteed to carry
    /// one, and the passwd entry is the shell whose profile is being asked for
    /// either way.
    private static func loginShell() -> String {
        if let entry = getpwuid(getuid())?.pointee.pw_shell {
            let shell = String(cString: entry)
            if !shell.isEmpty { return shell }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// The login shell's own PATH, or nil when it gives no usable answer.
    ///
    /// `-l` reads the login profile; `-i` is deliberately not passed, because
    /// the interactive rc starts every plugin the user has on a probe a reader
    /// can be made to wait for. That is the trade this makes: a PATH entry
    /// added only by an interactive rc is not seen. It costs nothing when it
    /// is wrong -- the merge only ever adds -- so a shell that answers in a
    /// form this does not understand leaves the inherited PATH intact.
    ///
    /// The answer is the last line of the output, not all of it: a profile may
    /// print, and `printf` writes the PATH after anything it printed with no
    /// newline of its own.
    private static func probeLoginShell(_ shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A profile that reads stdin would otherwise park on whatever
        // descriptor this process was launched with.
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            log.error("login shell \(shell, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard exited.wait(timeout: .now() + probeTimeout) == .success else {
            terminate(process)
            log.error("login shell \(shell, privacy: .public) did not answer within \(probeTimeout)s")
            return nil
        }
        guard process.terminationStatus == 0 else {
            log.error("login shell \(shell, privacy: .public) exited \(process.terminationStatus)")
            return nil
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        guard
            let text = String(data: data, encoding: .utf8),
            let line = text.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else { return nil }
        return line
    }

    /// SIGTERM is a request a shell parked inside a profile can refuse, and a
    /// probe that gave up must not leave one running against the app's own
    /// stdout pipe.
    private static func terminate(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(0.3)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
