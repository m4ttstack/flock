import AppKit
import Darwin
import FlockCore

/// `Flock release`: hides every running Flock so herdr's own clients size its
/// panes again, e.g. from a phone over ssh. Clicking Flock takes them back.
enum ReleaseCommand {
    static let signal = SIGUSR1

    static func run() -> Never {
        let records = FlockClientRegistry.shared.records()
        let targets = FlockReleaseTargets.targets(records: records, bundleIDOf: bundleID(of:))
        for older in records where older.hidesOnRelease != true && bundleID(of: older.pid) == older.bundleID {
            print("\(older.appName) (pid \(older.pid)) predates `release`; hide it with ⌘H or quit it")
        }
        guard !targets.isEmpty else {
            fflush(stdout)
            fputs("flock: no running Flock to release\n", stderr)
            exit(1)
        }
        for flock in targets where kill(flock.pid, signal) == 0 {
            print("\(flock.appName) (pid \(flock.pid)) hidden; its panes are herdr's until you click it")
        }
        exit(0)
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

/// The app's side of `Flock release`.
///
/// Hidden rather than closed: closing the window tears its surfaces down,
/// while hidden is the off-screen state `HerdrHoldCoordinator` already
/// releases on, and unhiding is an activation that takes the panes back.
@MainActor
enum ReleaseSignal {
    private static var source: DispatchSourceSignal?

    static func listen() {
        guard source == nil else { return }
        Darwin.signal(ReleaseCommand.signal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: ReleaseCommand.signal, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.hide(nil) }
        }
        source.resume()
        self.source = source
    }
}
