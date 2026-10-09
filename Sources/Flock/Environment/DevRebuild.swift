import AppKit
import FlockCore
import Observation

/// Flock Dev's Rebuild Flock Dev: runs `Scripts/dev-build.sh` in the checkout
/// this bundle was built into. The new bundle lands where this one runs from,
/// so `DevBuildWatcher` offers the restart once it does.
@MainActor
@Observable
final class DevRebuild {
    enum State: Equatable {
        case idle
        case building(started: Date, expected: TimeInterval)
        case failed(log: URL)
    }

    static let lastDurationKey = "flock.devRebuild.lastDuration"
    static let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Flock/dev-rebuild.log")

    private(set) var state: State = .idle

    var isBuilding: Bool {
        if case .building = state { true } else { false }
    }

    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notice: @MainActor (String) -> Void

    /// `state` is for renders.
    init(
        bundleURL: URL = Bundle.main.bundleURL, defaults: UserDefaults = .standard, state: State = .idle,
        notice: @escaping @MainActor (String) -> Void
    ) {
        self.bundleURL = bundleURL
        self.defaults = defaults
        self.state = state
        self.notice = notice
    }

    func start() async {
        guard !isBuilding else { return }
        guard let checkout = DevRebuildPlan.checkout(forBundle: bundleURL.path) else {
            return notice("Flock Dev isn't running from a checkout's build/dev folder.")
        }
        if let refusal = DevRebuildPlan.refusal(branch: await Self.branch(of: checkout)) {
            return notice(refusal)
        }
        let last = defaults.object(forKey: Self.lastDurationKey) as? TimeInterval
        let started = Date()
        state = .building(started: started, expected: DevRebuildPlan.expectedDuration(last: last))
        let succeeded = await Self.build(checkout: checkout)
        if succeeded {
            defaults.set(Date().timeIntervalSince(started), forKey: Self.lastDurationKey)
            state = .idle
        } else {
            state = .failed(log: Self.log)
        }
    }

    func openLog() {
        NSWorkspace.shared.open(Self.log)
    }

    /// nil on a detached HEAD or anything git cannot answer.
    private static func branch(of checkout: String) async -> String? {
        let runner = ToolRunner(binaryPath: "/usr/bin/git", environment: ToolPath.childEnvironment(), deadline: .seconds(5))
        guard let result = try? await runner.run(["-C", checkout, "symbolic-ref", "--short", "HEAD"]), result.exitCode == 0 else {
            return nil
        }
        let branch = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    /// No deadline: a cold build takes minutes, and the person can see it running.
    private static func build(checkout: String) async -> Bool {
        let checkoutURL = URL(fileURLWithPath: checkout)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: log) else { return false }
        let process = Process()
        process.executableURL = checkoutURL.appendingPathComponent("Scripts/dev-build.sh")
        process.currentDirectoryURL = checkoutURL
        process.environment = ToolPath.childEnvironment()
        process.standardOutput = output
        process.standardError = output
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                try? output.close()
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? output.close()
                continuation.resume(returning: false)
            }
        }
    }
}
