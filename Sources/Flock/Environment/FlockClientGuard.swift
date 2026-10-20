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

    private static var unregisterInstalled = false

    /// Writes this process's record for `socketPath`, replacing any earlier
    /// one. The unregister on quit is installed once however often this runs.
    static func register(socketPath: String) {
        let registry = FlockClientRegistry.shared
        let me = ProcessInfo.processInfo.processIdentifier
        ReleaseSignal.listen()
        try? registry.register(FlockClientRecord(
            pid: me,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Flock",
            socketPath: socketPath,
            hidesOnRelease: true
        ))
        guard !unregisterInstalled else { return }
        unregisterInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in registry.unregister(pid: me) }
    }

    static func settle(socketPath: String, defaultSocketPath: String) async {
        register(socketPath: socketPath)
        let others = conflicts(on: socketPath, defaultSocketPath: defaultSocketPath)
        guard let other = others.first else { return }

        switch ask(about: other, copy: launchCopy(other: other.appName), declineTitle: "Quit This One") {
        case .quitOther:
            await quit(others)
        case .decline:
            NSApp.terminate(nil)
        case .keepBoth:
            break
        }
    }

    /// Asked before this Flock moves to `socketPath`. False means stay where
    /// it is; true means go ahead, with any other Flock on that session
    /// either gone or knowingly kept.
    static func confirmAttach(socketPath: String, defaultSocketPath: String, stayLabel: String) async -> Bool {
        let others = conflicts(on: socketPath, defaultSocketPath: defaultSocketPath)
        guard let other = others.first else { return true }

        let target = HerdrServerAddress(socketPath: socketPath, home: NSHomeDirectory()).label
        let copy = switchCopy(other: other.appName, target: target)
        switch ask(about: other, copy: copy, declineTitle: "Stay on \(stayLabel)") {
        case .quitOther:
            await quit(others)
            return true
        case .decline:
            return false
        case .keepBoth:
            return true
        }
    }

    private static func conflicts(on socketPath: String, defaultSocketPath: String) -> [RunningFlock] {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningFlock? in
            guard let id = app.bundleIdentifier, flockBundleIDs.contains(id), !app.isTerminated else { return nil }
            return RunningFlock(pid: app.processIdentifier, bundleID: id, appName: app.localizedName ?? "Flock")
        }
        return FlockClientConflict.others(
            attachedTo: socketPath, selfPID: ProcessInfo.processInfo.processIdentifier,
            records: FlockClientRegistry.shared.records(),
            running: running, defaultSocketPath: defaultSocketPath
        )
    }

    struct AlertCopy: Equatable {
        let message: String
        let detail: String
    }

    static func launchCopy(other: String) -> AlertCopy {
        AlertCopy(
            message: "\(other) is also open on this herdr session",
            detail: "Two Flocks on one session fight over its panes: each takes them over and sizes "
                + "them to its own window. Quit \(other) to keep working here?"
        )
    }

    static func switchCopy(other: String, target: String) -> AlertCopy {
        AlertCopy(
            message: "\(other) is already open on \(target)",
            detail: "Two Flocks on one herdr session fight over pane sizes. "
                + "Quit \(other) to switch, stay where you are, or keep both."
        )
    }

    private enum Choice { case quitOther, decline, keepBoth }

    private static func ask(about other: RunningFlock, copy: AlertCopy, declineTitle: String) -> Choice {
        let alert = NSAlert()
        alert.messageText = copy.message
        alert.informativeText = copy.detail
        alert.addButton(withTitle: "Quit \(other.appName)")
        alert.addButton(withTitle: declineTitle)
        alert.addButton(withTitle: "Keep Both")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .quitOther
        case .alertSecondButtonReturn: return .decline
        default: return .keepBoth
        }
    }

    private static func quit(_ flocks: [RunningFlock]) async {
        for flock in flocks {
            NSRunningApplication(processIdentifier: flock.pid)?.terminate()
        }
        await waitForExit(of: flocks.map(\.pid))
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
