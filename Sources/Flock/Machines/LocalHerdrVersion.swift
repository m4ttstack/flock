import FlockCore
import Foundation
import Observation

/// This Mac's herdr version, read once per machine session: a remote herdr
/// that differs from it is the version warning's whole input.
@MainActor
@Observable
final class LocalHerdrVersion {
    private(set) var version: String?

    @ObservationIgnored private let read: @Sendable () -> String?
    @ObservationIgnored private var loaded = false

    init(read: @escaping @Sendable () -> String? = LocalHerdrVersion.readInstalled) {
        self.read = read
    }

    func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        let read = read
        version = await Task.detached(priority: .utility) { read() }.value
    }

    nonisolated static func readInstalled() -> String? {
        ToolPath.resolve("herdr")
            .flatMap { HerdrVersionReader().read(binaryPath: $0) }
            .flatMap { HerdrMousePatchVersion.parse(versionOutput: $0) }
    }
}
