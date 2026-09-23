import AppKit
import FlockCore

/// Runs before this Flock attaches to herdr: records which session it is
/// about to hold, and when another Flock already holds it, asks which one
/// should go. The two would otherwise take the same panes from each other.
@MainActor
enum FlockClientGuard {
    static let flockBundleIDs: Set<String> = ["dev.mattstack.Flock", "dev.mattstack.Flock.dev"]
    /// How long a quit Flock gets to let its panes go before this one attaches
    /// anyway.
    static let quitGrace: Duration = .seconds(5)

    static func settle(socketPath: String, defaultSocketPath: String) async {
        let registry = FlockClientRegistry.shared
        let me = ProcessInfo.processInfo.processIdentifier
        try? registry.register(FlockClientRecord(
            pid: me,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Flock",
            socketPath: socketPath
        ))
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in registry.unregister(pid: me) }

        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningFlock? in
            guard let id = app.bundleIdentifier, flockBundleIDs.contains(id), !app.isTerminated else { return nil }
            return RunningFlock(pid: app.processIdentifier, bundleID: id, appName: app.localizedName ?? "Flock")
        }
        let others = FlockClientConflict.others(
            attachedTo: socketPath, selfPID: me, records: registry.records(),
            running: running, defaultSocketPath: defaultSocketPath
        )
        guard let other = others.first else { return }

        switch ask(about: other) {
        case .quitOther:
            for flock in others {
                NSRunningApplication(processIdentifier: flock.pid)?.terminate()
            }
            await waitForExit(of: others.map(\.pid))
        case .quitThis:
            NSApp.terminate(nil)
        case .keepBoth:
            break
        }
    }

    private enum Choice { case quitOther, quitThis, keepBoth }

    private static func ask(about other: RunningFlock) -> Choice {
        let alert = NSAlert()
        alert.messageText = "\(other.appName) is also open on this herdr session"
        alert.informativeText = "Two Flocks on one session fight over its panes: each takes them over and sizes "
            + "them to its own window. Quit \(other.appName) to keep working here?"
        alert.addButton(withTitle: "Quit \(other.appName)")
        alert.addButton(withTitle: "Quit This One")
        alert.addButton(withTitle: "Keep Both")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .quitOther
        case .alertSecondButtonReturn: return .quitThis
        default: return .keepBoth
        }
    }

    private static func waitForExit(of pids: [Int32]) async {
        let deadline = ContinuousClock.now + quitGrace
        while ContinuousClock.now < deadline {
            let alive = pids.contains { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
            if !alive { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
