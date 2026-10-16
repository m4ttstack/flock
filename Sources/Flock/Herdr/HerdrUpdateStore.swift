import FlockCore
import Foundation
import Observation

/// herdr's API does not report its own update check, so this reads the
/// manifest herdr itself reads. Any failure hides the note rather than
/// raising an error: it is a courtesy, not a feature someone is waiting on.
@MainActor
@Observable
final class HerdrUpdateStore {
    private(set) var latest: String?

    @ObservationIgnored private let patchStore: HerdrMousePatchStore
    @ObservationIgnored private let installedVersion: @MainActor () -> String?
    @ObservationIgnored private let fetchLatest: @Sendable () async -> String?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastCheck: Date?

    static let interval: TimeInterval = 60 * 60

    init(
        patchStore: HerdrMousePatchStore,
        installedVersion: @escaping @MainActor () -> String?,
        fetchLatest: @escaping @Sendable () async -> String? = HerdrUpdateStore.fetchFromHerdr,
        now: @escaping () -> Date = Date.init
    ) {
        self.patchStore = patchStore
        self.installedVersion = installedVersion
        self.fetchLatest = fetchLatest
        self.now = now
    }

    var notice: HerdrUpdateNotice? {
        let patchInstalled: Bool = if case .installed = patchStore.state { true } else { false }
        let homebrew = patchStore.binaryPath.map {
            HerdrInstallKind.isHomebrew(resolvedPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        } ?? false
        return HerdrUpdateNotice.decide(
            installed: installedVersion(), latest: latest, patchInstalled: patchInstalled,
            catalogHasLatest: latest.flatMap(HerdrMousePatchCatalog.entry(for:)) != nil, homebrew: homebrew
        )
    }

    func checkIfDue() async {
        if let lastCheck, now().timeIntervalSince(lastCheck) < Self.interval { return }
        lastCheck = now()
        if let version = await fetchLatest() { latest = version }
    }

    nonisolated static func fetchFromHerdr() async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: HerdrLatestManifest.url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return HerdrLatestManifest.version(from: data)
    }
}
