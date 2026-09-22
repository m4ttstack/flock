import FlockCore
import Foundation
import Observation
import os

/// Where herd progress comes from. A test hands the store canned answers
/// here, so nothing under test runs `rt`.
struct HerdProgressSources: Sendable {
    /// `rt herd list --json`'s stdout, or nil for any failure to get it.
    var listHerds: @Sendable () async -> Data?
    /// `rt herd status --herd <id> --json`'s stdout, or nil likewise.
    var readStatus: @Sendable (_ herdID: String) async -> Data?

    static let live = HerdProgressSources(
        listHerds: { await successfulStdout(["herd", "list", "--json"]) },
        readStatus: { await successfulStdout(["herd", "status", "--herd", $0, "--json"]) }
    )

    private static func successfulStdout(_ arguments: [String]) async -> Data? {
        guard let result = await RtCommand.run(arguments), result.exitCode == 0 else { return nil }
        return result.stdout
    }
}

/// rt's account of each herd on the rail, keyed by the herdr workspace label
/// rt named the herd's workspace with.
///
/// Asked only about herds the rail is showing, one `rt herd status` each,
/// concurrently. A herd rt did not answer for has no entry, and its row falls
/// back to what herdr's panes say.
@MainActor
@Observable
final class HerdProgressStore {
    /// Each `rt` call takes a tenth of a second or two, and a worker's report
    /// is not something to see the instant it lands.
    static let interval: Duration = .seconds(10)

    private(set) var progress: [String: HerdProgress] = [:]

    @ObservationIgnored private let sources: HerdProgressSources
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.mattstack.flock", category: "herds")

    init(sources: HerdProgressSources = .live) {
        self.sources = sources
    }

    /// A call that arrives while a read is running waits for that one rather
    /// than starting a second round of `rt`.
    func refresh(labels: Set<String>) async {
        if let inFlight { return await inFlight.value }
        let task = Task {
            await self.read(labels: labels)
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func read(labels: Set<String>) async {
        guard !labels.isEmpty else {
            if !progress.isEmpty { progress = [:] }
            return
        }
        // A list that fails is rt having a bad moment, not every herd ending,
        // so the last answer stands until a list succeeds.
        guard let stdout = await sources.listHerds(), let listed = ListedHerd.fromHerdList(stdout: stdout) else {
            Self.log.debug("herd list failed; keeping \(self.progress.count, privacy: .public) herds")
            return
        }
        let wanted = listed.filter { labels.contains($0.workspaceLabel) }
        let sources = self.sources
        let fresh = await withTaskGroup(of: (String, HerdProgress?).self) { group in
            for herd in wanted {
                group.addTask {
                    (herd.workspaceLabel, await sources.readStatus(herd.id).flatMap(HerdProgress.fromHerdStatus(stdout:)))
                }
            }
            var answered: [String: HerdProgress] = [:]
            for await (label, progress) in group {
                if let progress { answered[label] = progress }
            }
            return answered
        }
        if fresh != progress { progress = fresh }
    }
}
