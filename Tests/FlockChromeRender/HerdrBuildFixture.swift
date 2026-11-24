import CryptoKit
import FlockCore
import Foundation
import XCTest

struct BytesTransport: HerdrDownloadTransport {
    let body: Data
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try body.write(to: destination)
    }
}

struct HangingTransport: HerdrDownloadTransport {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.4)
        try await Task.sleep(for: .seconds(3600))
    }
}

/// The first download lands `body`; every later one hangs part way.
final class OnceThenHangingTransport: HerdrDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var landed = false
    private let body: Data
    init(body: Data) { self.body = body }
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let isFirst = lock.withLock {
            defer { landed = true }
            return !landed
        }
        guard isFirst else { return try await HangingTransport().download(url, to: destination, progress: progress) }
        try body.write(to: destination)
    }
}

struct QuietHerdrRunner: HerdrCommandRunner {
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        (0, "")
    }
}

struct HangingHerdrRunner: HerdrCommandRunner {
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        try? await Task.sleep(for: .seconds(3600))
        return (1, "")
    }
}

struct RefusingHandoffRunner: HerdrCommandRunner {
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        (1, #"{"error":{"code":"handoff_failed","message":"handoff replacement server did not become ready"}}"#)
    }
}

/// `HerdrBuildStore`s for renders and window tests. Each probes a throwaway
/// file whose bytes start `herdr X`; the list, the download, the server
/// probe and the command runner are stubs, so nothing runs a binary, reaches
/// the network or reads a real install.
@MainActor
final class HerdrBuildFixture {
    static let stock = Data("herdr 0.9.5 stock build".utf8)
    static let ms1 = Data("herdr 0.9.5-ms.1 fork build".utf8)
    static let ms2 = Data("herdr 0.9.5-ms.2 fork build".utf8)

    struct Build {
        let version: String
        let bytes: Data
        var changesServer = true
        var supersedes: [Data] = []
    }

    let root: URL
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "flock-herdr-fixture-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    func remove() {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// No herdr on disk and no list, so no banner, pill or restart shows:
    /// what every window that is not about herdr wants. Its defaults suite
    /// is removed when the running test finishes.
    static func inert() -> HerdrBuildStore {
        let suite = "flock-herdr-fixture-inert-\(UUID().uuidString)"
        InertSuiteSweeper.shared.add(suite)
        return HerdrBuildStore(
            resolveBinaryPath: { nil },
            defaultInstallPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("flock-no-herdr-\(UUID().uuidString)/herdr").path,
            fetchList: { nil },
            defaults: UserDefaults(suiteName: suite)!,
            readVersionOutput: { _ in nil },
            arch: .arm64,
            runner: QuietHerdrRunner(),
            relaunch: {}
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func list(newest: String, _ builds: [Build]) -> HerdrBuildList {
        let entries = builds.map { build -> [String: Any] in
            let sha = sha256(build.bytes)
            let base = "https://github.com/m4ttstack/herdr/releases/download/v\(build.version)/"
            return [
                "version": build.version,
                "herdr": "0.9.5",
                "revision": 1,
                "changesServer": build.changesServer,
                "assets": [
                    "arm64": ["url": base + "herdr-macos-aarch64", "sha256": sha],
                    "x86_64": ["url": base + "herdr-macos-x86_64", "sha256": sha],
                ],
                "supersedes": build.supersedes.map(sha256),
            ]
        }
        let json: [String: Any] = ["schema": 1, "newest": newest, "builds": entries, "flockPatchSha256": [String]()]
        return HerdrBuildList.decode(try! JSONSerialization.data(withJSONObject: json))!
    }

    /// 0.9.5-ms.2 newest, superseding 0.9.5-ms.1.
    static var standardList: HerdrBuildList {
        list(newest: "0.9.5-ms.2", [
            Build(version: "0.9.5-ms.2", bytes: ms2, supersedes: [ms1]),
            Build(version: "0.9.5-ms.1", bytes: ms1),
        ])
    }

    /// One herdr per name: a store re-probes on every refresh, so two stores
    /// sharing a file would each read whatever the other wrote last.
    func installPath(_ name: String = "default") -> String {
        root.appendingPathComponent("\(name)/bin/herdr").path
    }

    func write(_ bytes: Data, name: String = "default") throws {
        let path = installPath(name)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true
        )
        try bytes.write(to: URL(fileURLWithPath: path))
    }

    /// `binary` nil leaves nothing on disk, so the state is `.missing`.
    func store(
        binary: Data?,
        name: String = "default",
        list: HerdrBuildList? = HerdrBuildFixture.standardList,
        transport: HerdrDownloadTransport = BytesTransport(body: HerdrBuildFixture.ms2),
        runner: HerdrCommandRunner = QuietHerdrRunner(),
        server: HerdrServerBinary = .unknown,
        cache: String = "cache"
    ) throws -> HerdrBuildStore {
        let installPath = installPath(name)
        if let binary {
            try write(binary, name: name)
        } else {
            try? FileManager.default.removeItem(atPath: installPath)
        }
        return HerdrBuildStore(
            resolveBinaryPath: { FileManager.default.fileExists(atPath: installPath) ? installPath : nil },
            defaultInstallPath: installPath,
            fetchList: { list },
            downloader: HerdrBuildDownloader(cacheDirectory: root.appendingPathComponent(cache), transport: transport),
            defaults: defaults,
            readVersionOutput: HerdrVersionFixture.read,
            arch: .arm64,
            serverSocketPath: { server == .unknown ? nil : "/tmp/acme/herdr.sock" },
            probeServer: { _, _ in server },
            runner: runner,
            relaunch: {}
        )
    }

    /// A store that updated herdr once and is part way through updating it
    /// again, with the first update's restart still to come.
    func storeUpdatingAgain(name: String, source: HerdrBuildStore.PendingConfirmation.Source) async throws -> HerdrBuildStore {
        let store = try store(
            binary: Self.ms1, name: name, transport: OnceThenHangingTransport(body: Self.ms2), cache: "cache-\(name)"
        )
        await Self.settle(store)
        store.requestInstall(source: source)
        store.confirmPendingAction()
        await Self.settle(store)
        XCTAssertEqual(store.restartReason, .updated)
        try write(Self.ms1, name: name)
        store.reprobe()
        store.requestInstall(source: source)
        store.confirmPendingAction()
        return store
    }

    /// The list read, and any install or server check the store began.
    static func settle(_ store: HerdrBuildStore) async {
        await store.listTask?.value
        await store.installTask?.value
        await store.serverCheckTask?.value
    }
}

/// `inert()` is called from harnesses that hold no test case, so the suites
/// it makes are removed by watching for the end of whichever test is running.
private final class InertSuiteSweeper: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = InertSuiteSweeper()

    private let lock = NSLock()
    private var suites: [String] = []
    private var observing = false

    @MainActor
    func add(_ suite: String) {
        let register = lock.withLock {
            suites.append(suite)
            defer { observing = true }
            return !observing
        }
        if register { XCTestObservationCenter.shared.addTestObserver(self) }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let finished = lock.withLock {
            defer { suites.removeAll() }
            return suites
        }
        for suite in finished { UserDefaults().removePersistentDomain(forName: suite) }
    }
}
