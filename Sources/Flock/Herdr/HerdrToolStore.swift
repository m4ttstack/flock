import FlockCore
import Foundation
import Observation

/// Resolves once, off the main actor, whether herdr is on this Mac, and
/// caches the answer for the app's life -- the same shape `ChatStore` uses
/// for its own binary probe. Starts optimistic (`isFound = true`): herdr
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

    init(probe: @escaping () async -> Bool = HerdrToolLocator.probeBinaryFound) {
        probeTask = Task { [weak self] in
            let found = await probe()
            self?.isFound = found
        }
    }
}
