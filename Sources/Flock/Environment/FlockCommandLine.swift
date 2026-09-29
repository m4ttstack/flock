import AppKit
import Darwin
import FlockCore

/// The `flock` shell command. Runs headless and exits; see `FlockCommand` for
/// what counts as a command.
enum FlockCommandLine {
    static let releaseSignal = SIGUSR1

    static func run(_ command: FlockCommand, name: String) -> Never {
        switch command {
        case .release:
            exit(release(name: name) ? 0 : 1)
        case .attach(let arguments):
            attach(name: name, herdrArguments: arguments)
        case .help:
            print(FlockCommand.usage(name: name))
            exit(0)
        case .unknown(let other):
            fputs("\(name): unknown command '\(other)'\n\n\(FlockCommand.usage(name: name))\n", stderr)
            exit(2)
        }
    }

    /// Hides every running Flock so herdr's own clients size its panes again.
    /// False when there was none to hide.
    private static func release(name: String) -> Bool {
        let records = FlockClientRegistry.shared.records()
        let targets = FlockReleaseTargets.targets(records: records, bundleIDOf: bundleID(of:))
        for older in records where older.hidesOnRelease != true && bundleID(of: older.pid) == older.bundleID {
            print("\(older.appName) (pid \(older.pid)) predates `release`; hide it with ⌘H or quit it")
        }
        guard !targets.isEmpty else {
            fflush(stdout)
            fputs("\(name): no running Flock to release\n", stderr)
            return false
        }
        for flock in targets where kill(flock.pid, releaseSignal) == 0 {
            print("\(flock.appName) (pid \(flock.pid)) hidden; its panes are herdr's until you click it")
        }
        fflush(stdout)
        return true
    }

    /// Replaces this process with herdr, so the terminal becomes a herdr
    /// client. herdr is looked up on the caller's own PATH first: over ssh
    /// that is the one the user set up, and Flock's cached login-shell PATH is
    /// only the fallback.
    private static func attach(name: String, herdrArguments: [String]) -> Never {
        if release(name: name) {
            // Outlasts `HoldPolicy.releaseDelay` plus the app's hide, so the
            // panes are unlocked before herdr's first size lands.
            usleep(800_000)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        guard let herdr = UserPath.resolve("herdr", on: path) ?? ToolPath.resolve("herdr") else {
            fputs("\(name): herdr is not on your PATH\n", stderr)
            exit(1)
        }
        let argv = ([herdr] + herdrArguments).map { strdup($0) } + [nil]
        execv(herdr, argv)
        fputs("\(name): could not start \(herdr): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    /// Read from the process's exec arguments, not `proc_pidpath`: that fails
    /// once `dev-build.sh` has swapped a new bundle in under a running Flock
    /// Dev, which is exactly the one waiting on its Restart pill.
    private static func bundleID(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let execPath = buffer[MemoryLayout<Int32>.size..<size].prefix { $0 != 0 }
        let app = URL(fileURLWithPath: String(decoding: execPath, as: UTF8.self))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: app)?.bundleIdentifier
    }
}

/// The app's side of `flock release`.
///
/// Hidden rather than closed: closing the window tears its surfaces down,
/// while hidden is the off-screen state `HerdrHoldCoordinator` already
/// releases on, and unhiding is an activation that takes the panes back.
@MainActor
enum ReleaseSignal {
    private static var source: DispatchSourceSignal?

    static func listen() {
        guard source == nil else { return }
        Darwin.signal(FlockCommandLine.releaseSignal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: FlockCommandLine.releaseSignal, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.hide(nil) }
        }
        source.resume()
        self.source = source
    }
}
