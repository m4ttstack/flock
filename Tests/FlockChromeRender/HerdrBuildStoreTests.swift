import CryptoKit
import FlockCore
import Foundation
import Observation
import XCTest

/// Every herdr here is a throwaway temp file whose bytes start `herdr X`;
/// the build list, download, server probe and command runner are all
/// stubbed, so nothing runs a binary, reaches the network or touches a real
/// install.
@MainActor
final class HerdrBuildStoreTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var installPath: String!
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite: String!

    private let stock = Data("herdr 0.9.5 stock build".utf8)
    private let ms1 = Data("herdr 0.9.5-ms.1 fork build".utf8)
    private let ms2 = Data("herdr 0.9.5-ms.2 fork build".utf8)
    private let ms3 = Data("herdr 0.9.5-ms.3 fork build".utf8)
    private let socket = "/tmp/acme/herdr.sock"

    private final class FileTransport: HerdrDownloadTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        let body: Data
        let beforeReturning: @Sendable () throws -> Void
        init(body: Data, beforeReturning: @escaping @Sendable () throws -> Void = {}) {
            self.body = body
            self.beforeReturning = beforeReturning
        }
        var downloads: Int { lock.withLock { started } }
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            lock.withLock { started += 1 }
            progress(0.5)
            try body.write(to: destination)
            try beforeReturning()
        }
    }

    private final class StubRunner: HerdrCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        let status: Int32
        let output: String
        init(status: Int32 = 0, output: String = "live handoff complete; server log: /tmp/herdr-server.log\n") {
            self.status = status
            self.output = output
        }
        var calls: [[String]] { lock.withLock { recorded } }
        func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
            lock.withLock { recorded.append([executable] + arguments) }
            return (status, output)
        }
    }

    private final class ServerStub: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: HerdrServerBinary
        init(_ answer: HerdrServerBinary) { self.answer = answer }
        func set(_ value: HerdrServerBinary) { lock.withLock { answer = value } }
        func probe(socket: String, binary: String) -> HerdrServerBinary { lock.withLock { answer } }
    }

    /// Hands out `lists` one fetch at a time; the last one repeats.
    private final class ListSource: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [HerdrBuildList?]
        private var fetched = 0
        init(_ lists: [HerdrBuildList?]) { self.lists = lists }
        var count: Int { lock.withLock { fetched } }
        func set(_ list: HerdrBuildList?) { lock.withLock { lists = [list] } }
        func next() -> HerdrBuildList? {
            lock.withLock {
                fetched += 1
                return lists.count > 1 ? lists.removeFirst() : lists.first ?? nil
            }
        }
    }

    /// Answers the first fetch with no list at once, then holds every later
    /// one open until the test answers it, in any order.
    private final class GatedLists: @unchecked Sendable {
        private let lock = NSLock()
        private var first = true
        private var waiting: [CheckedContinuation<HerdrBuildList?, Never>] = []
        var pending: Int { lock.withLock { waiting.count } }
        func next() async -> HerdrBuildList? {
            let isFirst = lock.withLock {
                defer { first = false }
                return first
            }
            if isFirst { return nil }
            return await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
        }
        func answer(_ index: Int, with list: HerdrBuildList?) {
            lock.withLock { waiting[index] }.resume(returning: list)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class PathBox {
        var path: String
        init(_ path: String) { self.path = path }
    }

    private final class Counter {
        var count = 0
    }

    override func setUpWithError() throws {
        suite = "flock-herdr-build-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        installPath = root.appendingPathComponent(".local/bin/herdr").path
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct BuildFixture {
        let version: String
        let bytes: Data
        var changesServer = true
        var supersedes: [Data] = []
    }

    private func list(newest: String, _ builds: [BuildFixture]) -> HerdrBuildList {
        let entries = builds.map { build -> [String: Any] in
            let sha = Self.sha256(build.bytes)
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
                "supersedes": build.supersedes.map(Self.sha256),
            ]
        }
        let json: [String: Any] = ["schema": 1, "newest": newest, "builds": entries, "flockPatchSha256": [String]()]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return HerdrBuildList.decode(data)!
    }

    private func standardList(changesServer: Bool = true) -> HerdrBuildList {
        list(newest: "0.9.5-ms.2", [
            BuildFixture(version: "0.9.5-ms.2", bytes: ms2, changesServer: changesServer, supersedes: [ms1]),
            BuildFixture(version: "0.9.5-ms.1", bytes: ms1),
        ])
    }

    private func writeBinary(_ bytes: Data) throws {
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: installPath).deletingLastPathComponent().path, withIntermediateDirectories: true
        )
        try bytes.write(to: URL(fileURLWithPath: installPath))
    }

    private func binaryBytes() -> Data? {
        FileManager.default.contents(atPath: installPath)
    }

    private func makeStore(
        binary: Data?,
        resolve: (() -> String?)? = nil,
        lists: ListSource? = nil,
        fetchList: (@Sendable () async -> HerdrBuildList?)? = nil,
        transport: HerdrDownloadTransport? = nil,
        runner: StubRunner = StubRunner(),
        server: ServerStub = ServerStub(.unknown),
        socket: String? = nil,
        clock: Clock = Clock(),
        versionReads: Counter? = nil,
        relaunch: (() -> Void)? = nil,
        onBinaryPathChanged: @escaping () -> Void = {}
    ) throws -> HerdrBuildStore {
        if let binary { try writeBinary(binary) }
        let lists = lists ?? ListSource([standardList()])
        let installPath = installPath!
        return HerdrBuildStore(
            resolveBinaryPath: resolve ?? { FileManager.default.fileExists(atPath: installPath) ? installPath : nil },
            defaultInstallPath: installPath,
            fetchList: fetchList ?? { lists.next() },
            downloader: HerdrBuildDownloader(
                cacheDirectory: root.appendingPathComponent("cache"), transport: transport ?? FileTransport(body: ms2)
            ),
            defaults: defaults,
            readVersionOutput: {
                versionReads?.count += 1
                return HerdrVersionFixture.read($0)
            },
            arch: .arm64,
            now: { clock.now },
            serverSocketPath: { socket },
            probeServer: { server.probe(socket: $0, binary: $1) },
            runner: runner,
            relaunch: relaunch ?? { XCTFail("relaunched") },
            onBinaryPathChanged: onBinaryPathChanged
        )
    }

    private func settle(_ store: HerdrBuildStore) async {
        await store.listTask?.value
        await store.installTask?.value
        await store.serverCheckTask?.value
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held")
    }

    private func confirmAndWait(_ store: HerdrBuildStore) async {
        store.confirmPendingAction()
        await settle(store)
    }

    func testMissingHerdrInstallsWithoutConfirmationAndRunsIntegration() async throws {
        let runner = StubRunner()
        let installs = Counter()
        let store = try makeStore(binary: nil, runner: runner, onBinaryPathChanged: { installs.count += 1 })
        await settle(store)
        XCTAssertEqual(store.state, .missing(installPath: installPath))

        store.installMissing()
        XCTAssertNil(store.pendingConfirmation)
        await settle(store)

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(binaryBytes(), ms2)
        XCTAssertEqual(runner.calls, [[installPath, "integration", "install", "claude"]])
        XCTAssertEqual(installs.count, 1)
        XCTAssertNil(store.restartReason)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(store.state, .current(version: "0.9.5-ms.2"))
        XCTAssertEqual(store.binaryPath, installPath)
    }

    func testIntegrationFailureKeepsInstallAndSaysWhatToRun() async throws {
        let installs = Counter()
        let store = try makeStore(binary: nil, runner: StubRunner(status: 1, output: "boom"), onBinaryPathChanged: {
            installs.count += 1
        })
        await settle(store)

        store.installMissing()
        await settle(store)

        XCTAssertEqual(binaryBytes(), ms2)
        XCTAssertEqual(store.lastErrorMessage, HerdrBuildCopy.integrationFailed)
        XCTAssertEqual(installs.count, 1)
    }

    private func toolStore() async -> HerdrToolStore {
        let path = installPath!
        let tools = HerdrToolStore(probe: { FileManager.default.fileExists(atPath: path) })
        await tools.probeTask.value
        return tools
    }

    func testHerdrInstalledElsewhereDuringTheMissingInstallLiftsTheMissingScreen() async throws {
        let tools = await toolStore()
        XCTAssertFalse(tools.isFound)
        let path = installPath!
        let fork = ms2
        let transport = FileTransport(body: ms2) {
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true
            )
            try fork.write(to: URL(fileURLWithPath: path))
        }
        let store = try makeStore(binary: nil, transport: transport, onBinaryPathChanged: { tools.recheckIfMissing() })
        await settle(store)

        store.installMissing()
        await settle(store)
        await tools.probeTask.value

        XCTAssertEqual(store.lastErrorMessage, HerdrBuildCopy.herdrChanged)
        XCTAssertEqual(store.state, .current(version: "0.9.5-ms.2"))
        XCTAssertTrue(tools.isFound)
    }

    func testHerdrInstalledByHandIsFoundOnTheNextRefresh() async throws {
        let tools = await toolStore()
        let store = try makeStore(binary: nil, onBinaryPathChanged: { tools.recheckIfMissing() })
        await settle(store)

        try writeBinary(stock)
        store.refresh()
        await settle(store)
        await tools.probeTask.value

        XCTAssertEqual(store.binaryPath, installPath)
        XCTAssertTrue(tools.isFound)
    }

    func testAnInstalledBuildIsNotKeptInTheDownloadCache() async throws {
        let store = try makeStore(binary: nil)
        await settle(store)

        store.installMissing()
        await settle(store)

        XCTAssertEqual(binaryBytes(), ms2)
        let cache = root.appendingPathComponent("cache").path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache), [])
    }

    func testHerdrRemovedMidSessionKeepsTheSessionUp() async throws {
        try writeBinary(stock)
        let tools = await toolStore()
        let store = try makeStore(binary: stock, onBinaryPathChanged: { tools.recheckIfMissing() })
        await settle(store)

        try FileManager.default.removeItem(atPath: installPath)
        store.refresh()
        await settle(store)
        await tools.probeTask.value

        XCTAssertNil(store.binaryPath)
        XCTAssertTrue(tools.isFound)
    }

    func testStockInstallAsksFirst() async throws {
        let runner = StubRunner()
        let store = try makeStore(binary: stock, runner: runner)
        await settle(store)
        XCTAssertEqual(store.state, .stock(installPath: installPath, installed: "0.9.5", newest: "0.9.5-ms.2"))

        store.requestInstall(source: .settings)
        XCTAssertEqual(
            store.pendingConfirmation,
            HerdrBuildStore.PendingConfirmation(
                action: .install(HerdrBuildStore.InstallOffer(
                    newest: "0.9.5-ms.2",
                    installPath: installPath,
                    probe: HerdrBuildInstaller.Probe(
                        exists: true, isWritable: true, version: HerdrBuildVersion("0.9.5"), sha256: Self.sha256(stock)
                    )
                )),
                confirmation: HerdrBuildCopy.installConfirmation(installPath: installPath, newest: "0.9.5-ms.2"),
                source: .settings
            )
        )
        XCTAssertTrue(store.pendingConfirmation?.confirmation.message.contains(installPath) ?? false)
        XCTAssertEqual(binaryBytes(), stock)

        await confirmAndWait(store)

        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(binaryBytes(), ms2)
        XCTAssertEqual(store.restartReason, .installed)
        XCTAssertEqual(store.state, .current(version: "0.9.5-ms.2"))
        XCTAssertTrue(runner.calls.isEmpty, "only a fresh install sets up the integration")
    }

    func testOutdatedUpdateAsksFirst() async throws {
        let store = try makeStore(binary: ms1)
        await settle(store)
        XCTAssertEqual(store.state, .outdated(installPath: installPath, installed: "0.9.5-ms.1", newest: "0.9.5-ms.2"))
        XCTAssertEqual(store.availableUpdate, "0.9.5-ms.2")

        store.requestInstall(source: .banner)
        XCTAssertEqual(
            store.pendingConfirmation?.confirmation,
            HerdrBuildCopy.updateConfirmation(installPath: installPath, newest: "0.9.5-ms.2")
        )
        XCTAssertEqual(store.pendingConfirmation?.source, .banner)
        XCTAssertEqual(binaryBytes(), ms1)

        await confirmAndWait(store)

        XCTAssertEqual(binaryBytes(), ms2)
        XCTAssertEqual(store.restartReason, .updated)
        XCTAssertNil(store.availableUpdate)
    }

    func testRequestInstallAsksNothingWhereThereIsNothingToReplace() async throws {
        let current = try makeStore(binary: ms2)
        await settle(current)
        current.requestInstall(source: .settings)
        XCTAssertNil(current.pendingConfirmation)

        try FileManager.default.removeItem(atPath: installPath)
        let missing = try makeStore(binary: nil)
        await settle(missing)
        missing.requestInstall(source: .settings)
        XCTAssertNil(missing.pendingConfirmation)
    }

    func testListUnavailableLeavesBinaryAndRetriesOnInstall() async throws {
        let unread = try makeStore(binary: stock, lists: ListSource([nil]))
        await settle(unread)
        XCTAssertEqual(unread.state, .listUnavailable(installed: "0.9.5"))
        unread.requestInstall(source: .settings)
        XCTAssertNil(unread.pendingConfirmation)
        XCTAssertEqual(binaryBytes(), stock)
        try FileManager.default.removeItem(atPath: installPath)

        let neverRead = ListSource([nil, nil])
        let failing = try makeStore(binary: nil, lists: neverRead)
        await settle(failing)
        XCTAssertEqual(failing.state, .missing(installPath: installPath))
        failing.installMissing()
        await settle(failing)
        XCTAssertEqual(failing.lastErrorMessage, HerdrBuildCopy.listUnreadable)
        XCTAssertEqual(neverRead.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installPath))
        XCTAssertEqual(failing.phase, .idle)

        let readOnRetry = ListSource([nil, standardList()])
        let retrying = try makeStore(binary: nil, lists: readOnRetry)
        await settle(retrying)
        retrying.installMissing()
        await settle(retrying)
        XCTAssertNil(retrying.lastErrorMessage)
        XCTAssertEqual(binaryBytes(), ms2)
    }

    func testChecksumMismatchChangesNothing() async throws {
        let store = try makeStore(binary: stock, transport: FileTransport(body: Data("<html>".utf8)))
        await settle(store)

        store.requestInstall(source: .banner)
        await confirmAndWait(store)

        XCTAssertEqual(store.lastErrorMessage, HerdrBuildCopy.checksumMismatch)
        XCTAssertEqual(store.bannerErrorMessage, HerdrBuildCopy.checksumMismatch)
        XCTAssertTrue(store.showsBanner)
        XCTAssertEqual(binaryBytes(), stock)
        XCTAssertNil(store.restartReason)
        XCTAssertEqual(store.phase, .idle)
    }

    func testOnlyAnInstallTheBannerAskedForReportsItsFailureOnTheBanner() async throws {
        let store = try makeStore(binary: stock, transport: FileTransport(body: Data("<html>".utf8)))
        await settle(store)

        store.requestInstall(source: .settings)
        await confirmAndWait(store)

        XCTAssertEqual(store.lastErrorMessage, HerdrBuildCopy.checksumMismatch)
        XCTAssertNil(store.bannerErrorMessage)
    }

    func testBinaryChangedDuringDownloadIsLeftAlone() async throws {
        let replacement = Data("herdr 0.9.6 installed by hand".utf8)
        let path = installPath!
        let transport = FileTransport(body: ms2) { try replacement.write(to: URL(fileURLWithPath: path)) }
        let store = try makeStore(binary: stock, transport: transport)
        await settle(store)

        store.requestInstall(source: .settings)
        await confirmAndWait(store)

        XCTAssertEqual(store.lastErrorMessage, HerdrBuildCopy.herdrChanged)
        XCTAssertEqual(binaryBytes(), replacement)
        XCTAssertNil(store.restartReason)
    }

    func testListRefetchedHourly() async throws {
        let clock = Clock()
        let start = clock.now
        let lists = ListSource([standardList()])
        let store = try makeStore(binary: stock, lists: lists, clock: clock)
        await settle(store)
        XCTAssertEqual(lists.count, 1)

        clock.now = start.addingTimeInterval(10 * 60)
        store.refresh()
        await settle(store)
        XCTAssertEqual(lists.count, 1)

        clock.now = start.addingTimeInterval(61 * 60)
        store.refresh()
        store.refresh()
        await settle(store)
        XCTAssertEqual(lists.count, 2, "a fetch already under way is not started again")
    }

    func testBannerOfferAndDismissal() async throws {
        let lists = ListSource([standardList()])
        let store = try makeStore(binary: stock, lists: lists)
        await settle(store)
        XCTAssertTrue(store.shouldOfferBanner)
        XCTAssertTrue(store.showsBanner)

        store.dismissBannerOffer()

        XCTAssertFalse(store.shouldOfferBanner)
        XCTAssertFalse(store.showsBanner)
        XCTAssertEqual(defaults.string(forKey: "flock.herdrBuild.offerDismissedFor"), "0.9.5-ms.2")

        lists.set(list(newest: "0.9.5-ms.3", [
            BuildFixture(version: "0.9.5-ms.3", bytes: ms3, supersedes: [ms1, ms2]),
            BuildFixture(version: "0.9.5-ms.2", bytes: ms2, supersedes: [ms1]),
        ]))
        await store.refreshList()

        XCTAssertEqual(store.state, .stock(installPath: installPath, installed: "0.9.5", newest: "0.9.5-ms.3"))
        XCTAssertTrue(store.shouldOfferBanner)
    }

    func testServerRestartNeededOnlyForCurrentChangesServerBuild() async throws {
        let current = try makeStore(binary: ms2, server: ServerStub(.other), socket: socket)
        await settle(current)
        XCTAssertTrue(current.needsServerRestart)
        XCTAssertEqual(current.restartPrompt, .serverBehind)

        let onDisk = try makeStore(binary: ms2, server: ServerStub(.onDisk), socket: socket)
        await settle(onDisk)
        XCTAssertFalse(onDisk.needsServerRestart)
        XCTAssertNil(onDisk.restartPrompt)

        let clientOnly = try makeStore(
            binary: ms2, lists: ListSource([standardList(changesServer: false)]), server: ServerStub(.other), socket: socket
        )
        await settle(clientOnly)
        XCTAssertFalse(clientOnly.needsServerRestart)

        let outdated = try makeStore(binary: ms1, server: ServerStub(.other), socket: socket)
        await settle(outdated)
        XCTAssertFalse(outdated.needsServerRestart)
    }

    func testAServerThatIsNotThisMacsIsNeverPressed() async throws {
        let store = try makeStore(binary: ms2, server: ServerStub(.other), socket: nil)
        await settle(store)
        XCTAssertEqual(store.serverBinary, .unknown)
        XCTAssertFalse(store.needsServerRestart)
    }

    func testRestartingHandsTheServerOffToTheBinaryOnDiskThenRelaunches() async throws {
        let runner = StubRunner()
        let relaunches = Counter()
        let store = try makeStore(
            binary: ms2, runner: runner, server: ServerStub(.other), socket: socket, relaunch: { relaunches.count += 1 }
        )
        await settle(store)

        store.requestServerRestart(source: .banner)
        XCTAssertEqual(store.pendingConfirmation?.action, .restartServer)
        XCTAssertEqual(store.pendingConfirmation?.confirmation, HerdrBuildCopy.serverRestartConfirmation)
        XCTAssertEqual(relaunches.count, 0, "nothing runs before the confirmation")
        store.confirmPendingAction()
        XCTAssertTrue(store.serverRestarting)
        await store.serverRestartTask?.value

        XCTAssertEqual(
            runner.calls,
            [[installPath, "server", "live-handoff", "--import-exe", installPath, "--expected-version", "0.9.5-ms.2"]]
        )
        XCTAssertEqual(relaunches.count, 1)
        XCTAssertNil(store.serverRestartError)
    }

    func testARefusedHandoffKeepsFlockRunningAndSaysHowToFinishByHand() async throws {
        let runner = StubRunner(
            status: 1, output: #"{"error":{"code":"handoff_failed","message":"handoff replacement server did not become ready"}}"#
        )
        let server = ServerStub(.other)
        let store = try makeStore(binary: ms2, runner: runner, server: server, socket: socket)
        await settle(store)

        store.requestServerRestart(source: .settings)
        store.confirmPendingAction()
        await store.serverRestartTask?.value
        await settle(store)

        XCTAssertFalse(store.serverRestarting)
        XCTAssertEqual(
            store.serverRestartError,
            "herdr's server didn't restart: handoff replacement server did not become ready. To finish by hand, run "
                + "herdr server stop in a terminal, then reopen Flock. That ends every pane's shell and agent."
        )
        XCTAssertTrue(store.needsServerRestart)

        server.set(.unknown)
        store.checkServer()
        await settle(store)
        XCTAssertNotNil(store.serverRestartError, "an unreadable server says nothing about the failure")

        server.set(.onDisk)
        store.checkServer()
        await settle(store)
        XCTAssertNil(store.serverRestartError)
        XCTAssertNil(store.restartPrompt)
    }

    func testNoRestartIsOfferedWhileNoneIsNeeded() async throws {
        let store = try makeStore(binary: ms2, server: ServerStub(.onDisk), socket: socket)
        await settle(store)

        store.requestServerRestart(source: .banner)
        XCTAssertNil(store.pendingConfirmation)
    }

    func testNotNowSilencesTheServerBannerForThisBuildOnly() async throws {
        let store = try makeStore(binary: ms2, server: ServerStub(.other), socket: socket)
        await settle(store)
        XCTAssertEqual(store.bannerRestartPrompt, .serverBehind)

        store.dismissServerBehindBanner()

        XCTAssertNil(store.bannerRestartPrompt)
        XCTAssertEqual(store.restartPrompt, .serverBehind)
        XCTAssertEqual(defaults.string(forKey: "flock.herdrBuild.serverBehindDismissedFor"), "0.9.5-ms.2")

        let relaunched = try makeStore(binary: nil, server: ServerStub(.other), socket: socket)
        await settle(relaunched)
        XCTAssertNil(relaunched.bannerRestartPrompt, "the dismissal outlives the launch")

        defaults.set("0.9.5-ms.1", forKey: "flock.herdrBuild.serverBehindDismissedFor")
        let older = try makeStore(binary: nil, server: ServerStub(.other), socket: socket)
        await settle(older)
        XCTAssertEqual(older.bannerRestartPrompt, .serverBehind, "a dismissal for another build does not carry over")
    }

    func testARefreshWithNothingChangedDoesNotReadHerdrAgain() async throws {
        let reads = Counter()
        let store = try makeStore(binary: stock, versionReads: reads)
        await settle(store)
        XCTAssertEqual(reads.count, 1)

        store.refresh()
        XCTAssertEqual(reads.count, 1)

        store.reprobe()
        XCTAssertEqual(reads.count, 2)

        try ms1.write(to: URL(fileURLWithPath: installPath))
        store.refresh()
        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(store.binaryVersion, HerdrBuildVersion("0.9.5-ms.1"))
    }

    private var ms3List: HerdrBuildList {
        list(newest: "0.9.5-ms.3", [
            BuildFixture(version: "0.9.5-ms.3", bytes: ms3, supersedes: [ms1, ms2]),
            BuildFixture(version: "0.9.5-ms.2", bytes: ms2, supersedes: [ms1]),
        ])
    }

    func testAFailedRefetchKeepsTheListAndRetriesOnTheNextRefresh() async throws {
        let clock = Clock()
        let lists = ListSource([standardList(), nil, standardList()])
        let store = try makeStore(binary: ms1, lists: lists, clock: clock)
        await settle(store)
        let outdated = HerdrBuildState.outdated(installPath: installPath, installed: "0.9.5-ms.1", newest: "0.9.5-ms.2")
        XCTAssertEqual(store.state, outdated)

        clock.now = clock.now.addingTimeInterval(61 * 60)
        store.refresh()
        await settle(store)
        XCTAssertEqual(lists.count, 2)
        XCTAssertNotNil(store.list)
        XCTAssertEqual(store.state, outdated)
        XCTAssertEqual(store.availableUpdate, "0.9.5-ms.2")

        store.refresh()
        await settle(store)
        XCTAssertEqual(lists.count, 3, "a failed fetch is not counted as fresh")
    }

    func testALateListResultDoesNotReplaceANewerOne() async throws {
        let gated = GatedLists()
        let store = try makeStore(binary: stock, fetchList: { await gated.next() })
        await settle(store)
        let older = Task { await store.refreshList() }
        await waitUntil { gated.pending == 1 }
        let newer = Task { await store.refreshList() }
        await waitUntil { gated.pending == 2 }

        gated.answer(1, with: ms3List)
        await newer.value
        gated.answer(0, with: standardList())
        await older.value

        XCTAssertEqual(store.list?.newest.version.display, "0.9.5-ms.3")
        XCTAssertEqual(store.state, .stock(installPath: installPath, installed: "0.9.5", newest: "0.9.5-ms.3"))
    }

    func testConfirmingWhileAnInstallRunsStartsNoSecondInstall() async throws {
        let transport = FileTransport(body: ms2)
        let store = try makeStore(binary: stock, transport: transport)
        await settle(store)
        store.requestInstall(source: .settings)
        XCTAssertNotNil(store.pendingConfirmation)

        try FileManager.default.removeItem(atPath: installPath)
        store.refresh()
        XCTAssertEqual(store.state, .missing(installPath: installPath))
        store.installMissing()
        XCTAssertNotEqual(store.phase, .idle)
        try writeBinary(stock)
        store.refresh()

        store.confirmPendingAction()
        XCTAssertNil(store.pendingConfirmation)
        await settle(store)

        XCTAssertEqual(transport.downloads, 1)
    }

    func testAConfirmationForABuildTheListNoLongerNamesInstallsNothing() async throws {
        let transport = FileTransport(body: ms2)
        let lists = ListSource([standardList()])
        let store = try makeStore(binary: stock, lists: lists, transport: transport)
        await settle(store)
        store.requestInstall(source: .settings)
        XCTAssertEqual(store.pendingConfirmation?.confirmation.title, "Install herdr 0.9.5-ms.2?")

        lists.set(ms3List)
        await store.refreshList()
        store.confirmPendingAction()
        await settle(store)

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(binaryBytes(), stock)
        XCTAssertNil(store.restartReason)

        store.requestInstall(source: .settings)
        XCTAssertEqual(store.pendingConfirmation?.confirmation.title, "Install herdr 0.9.5-ms.3?")
    }

    func testAConfirmationForAnotherPathInstallsNothing() async throws {
        let transport = FileTransport(body: ms2)
        let resolved = PathBox(installPath)
        let store = try makeStore(binary: stock, resolve: { resolved.path }, transport: transport)
        await settle(store)
        store.requestInstall(source: .settings)
        XCTAssertNotNil(store.pendingConfirmation)

        // The same bytes, so only the path tells the two herdrs apart.
        let other = root.appendingPathComponent("elsewhere/herdr")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stock.write(to: other)
        resolved.path = other.path
        store.refresh()
        XCTAssertEqual(store.state, .stock(installPath: other.path, installed: "0.9.5", newest: "0.9.5-ms.2"))
        await confirmAndWait(store)

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(FileManager.default.contents(atPath: other.path), stock)
        XCTAssertEqual(binaryBytes(), stock)
        XCTAssertNil(store.restartReason)
        XCTAssertEqual(store.phase, .idle)
    }

    func testAConfirmationForABinaryReplacedMeanwhileInstallsNothing() async throws {
        let transport = FileTransport(body: ms2)
        let store = try makeStore(binary: stock, transport: transport)
        await settle(store)
        store.requestInstall(source: .banner)
        XCTAssertNotNil(store.pendingConfirmation)

        try writeBinary(ms1)
        store.refresh()
        XCTAssertEqual(store.state, .outdated(installPath: installPath, installed: "0.9.5-ms.1", newest: "0.9.5-ms.2"))
        await confirmAndWait(store)

        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(transport.downloads, 0)
        XCTAssertEqual(binaryBytes(), ms1)
        XCTAssertNil(store.restartReason)
        XCTAssertEqual(store.phase, .idle)
    }

    func testAConfirmationOutlivesARefreshThatFindsNothingChanged() async throws {
        let store = try makeStore(binary: stock)
        await settle(store)
        store.requestInstall(source: .settings)

        store.refresh()
        store.reprobe()
        await confirmAndWait(store)

        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(binaryBytes(), ms2)
        XCTAssertEqual(store.restartReason, .installed)
    }

    func testNoRestartIsOfferedWhileALaterInstallRuns() async throws {
        let lists = ListSource([standardList()])
        let store = try makeStore(binary: ms1, lists: lists)
        await settle(store)
        store.requestInstall(source: .settings)
        await confirmAndWait(store)
        XCTAssertEqual(store.restartPrompt, .updated)
        XCTAssertEqual(store.bannerRestartPrompt, .updated)

        lists.set(ms3List)
        await store.refreshList()
        store.requestInstall(source: .settings)
        store.confirmPendingAction()
        XCTAssertNotEqual(store.phase, .idle)
        XCTAssertNil(store.restartPrompt)
        XCTAssertNil(store.bannerRestartPrompt)
        await settle(store)

        XCTAssertEqual(store.lastErrorMessage, HerdrBuildCopy.checksumMismatch)
        XCTAssertEqual(store.restartPrompt, .updated, "the first install still waits on a restart")
        XCTAssertEqual(store.bannerRestartPrompt, .updated)
    }

    func testDismissingTheOfferIsObserved() async throws {
        let store = try makeStore(binary: stock)
        await settle(store)
        let changed = Flag()
        withObservationTracking { _ = store.shouldOfferBanner } onChange: { changed.raise() }

        store.dismissBannerOffer()

        XCTAssertTrue(changed.isRaised)
        XCTAssertFalse(store.shouldOfferBanner)
        XCTAssertEqual(store.offerDismissedFor, "0.9.5-ms.2")
    }
}
