import FlockCore
import Foundation
import Observation

/// Resolves off the main actor whether herdr is on this Mac -- the same shape
/// `ChatStore` uses for its own binary probe. Once found, the answer holds
/// for the app's life. Starts optimistic (`isFound = true`): herdr
/// being present is the ordinary case, and only that default keeps a normal
/// launch from ever showing the missing-herdr screen for the probe's own
/// brief window.
@MainActor
@Observable
final class HerdrToolStore {
    private(set) var isFound = true

    /// Exposed only so a test can await the exact moment the probe settles;
    /// no production call site touches it.
    @ObservationIgnored private(set) var probeTask: Task<Void, Never> = Task {}

    @ObservationIgnored private let probe: () async -> Bool

    init(probe: @escaping () async -> Bool = HerdrToolLocator.probeBinaryFound) {
        self.probe = probe
        recheck()
    }

    /// A herdr that vanishes mid-session leaves its server running on the
    /// deleted binary, so a session that started never falls back to the
    /// missing screen.
    func recheckIfMissing() {
        guard !isFound else { return }
        recheck()
    }

    private func recheck() {
        probeTask.cancel()
        probeTask = Task { [weak self, probe] in
            let found = await probe()
            guard !Task.isCancelled else { return }
            self?.isFound = found
        }
    }
}
