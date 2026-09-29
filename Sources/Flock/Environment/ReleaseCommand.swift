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
            fputs("flock: no Flock is running\n", stderr)
            exit(1)
        }
        for flock in targets where kill(flock.pid, signal) == 0 {
            print("\(flock.appName) (pid \(flock.pid)) hidden; its panes are herdr's until you click it")
        }
        exit(0)
    }

    private static func bundleID(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let app = URL(fileURLWithPath: String(cString: buffer))
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
