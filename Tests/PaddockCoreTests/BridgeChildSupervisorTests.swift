import XCTest
@testable import PaddockCore

/// The supervisor driven against real child processes on real pipes, which is
/// the only way the descriptor lifetime it manages is the real thing: a fake
/// that hands back bare numbers would not reproduce a `Pipe` closing a
/// descriptor its handle still owns.
final class BridgeChildSupervisorTests: XCTestCase {
    // MARK: - harness

    /// Spawns a real child per take. `script` is run by `/bin/sh`, so a test
    /// picks whether the child lingers (a herdr that attached) or exits at once
    /// (a herdr that refused the attach).
    private final class Spawner: @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [String]
        private(set) var spawns: [PTYSize] = []
        /// Every child ever spawned, kept alive so a test can reap them and so
        /// no `Pipe` deallocates earlier here than it would in the bridge.
        private(set) var children: [Process] = []
        /// Where each child's stdin is copied to, one file per child.
        private(set) var sinks: [URL] = []

        init(scripts: [String]) {
            self.scripts = scripts
        }

        func spawn(_ size: PTYSize) -> BridgeChildSupervisor.Spawned? {
            lock.lock()
            let script = scripts.isEmpty ? "cat > \"$SINK\"" : scripts.removeFirst()
            let sink = FileManager.default.temporaryDirectory
                .appendingPathComponent("paddock-supervisor-\(UUID().uuidString).sink")
            spawns.append(size)
            sinks.append(sink)
            lock.unlock()

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]
            var env = ProcessInfo.processInfo.environment
            env["SINK"] = sink.path
            proc.environment = env
            let toChild = Pipe()
            let fromChild = Pipe()
            proc.standardInput = toChild
            proc.standardOutput = fromChild
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return nil }
            lock.lock()
            children.append(proc)
            lock.unlock()
            return (proc, toChild.fileHandleForWriting, fromChild.fileHandleForReading)
        }

        var spawnCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return spawns.count
        }

        func sink(_ index: Int) -> String {
            lock.lock()
            let url = sinks[index]
            lock.unlock()
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        func terminateAll() {
            lock.lock()
            let running = children
            let files = sinks
            lock.unlock()
            for proc in running where proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// A supervisor with its first child already spawned and its IO attached,
    /// wired the way `ControlBridge.run` wires them.
    private func makeSupervisor(
        spawner: Spawner,
        status: Pipe? = nil,
        retries: LockedBox<[TimeInterval]>? = nil,
        runRetries: Bool = true
    ) -> (BridgeChildSupervisor, BridgeIO) {
        let supervisor = BridgeChildSupervisor(
            ptySize: { PTYSize(cols: 80, rows: 24) },
            scheduleRetry: { delay, work in
                retries?.mutate { $0.append(delay) }
                guard runRetries else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01, execute: work)
            },
            spawn: { spawner.spawn($0) }
        )
        let first = supervisor.startFirstChild()
        XCTAssertNotNil(first, "the first child failed to spawn")
        let io = BridgeIO(
            herdrInFD: -1,
            stdinFD: Pipe().fileHandleForReading.fileDescriptor,
            stdoutFD: Pipe().fileHandleForWriting.fileDescriptor,
            statusFD: status?.fileHandleForWriting.fileDescriptor ?? -1,
            spawnedSize: PTYSize(cols: 80, rows: 24), ptySize: { PTYSize(cols: 80, rows: 24) },
            onHold: { supervisor.handle($0) },
            onSurfaceGone: { supervisor.shutdown() },
            onPeerGone: { supervisor.herdrOutputEnded(generation: $0) }
        )
        supervisor.attach(io: io)
        io.swapHerdrInput(to: first!.input)
        supervisor.installOutput(for: first!)
        supervisor.startWatching()
        return (supervisor, io)
    }

    private func waitUntil(
        _ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(10_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - release and take

    /// The descriptor a retake installs belongs to the NEW child's pipe, and it
    /// is still open once the previous child has been reaped. Closing the
    /// previous descriptor by NUMBER rather than through its handle leaves the
    /// old `Pipe`'s own handle to close that number a second time, after the
    /// new child's `pipe()` has already reclaimed it.
    func testARetakeLeavesItsOwnDescriptorOpenOnceThePreviousChildIsReaped() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let (supervisor, io) = makeSupervisor(spawner: spawner)

        supervisor.handle(.release)
        waitUntil("the released child to exit") { spawner.spawnCount == 1 && !spawner.children[0].isRunning }
        supervisor.handle(.take)
        waitUntil("the retake to spawn") { spawner.spawnCount == 2 }

        let installed = io.herdrInputDescriptor
        XCTAssertGreaterThanOrEqual(installed, 0, "the retake installed no descriptor at all")
        XCTAssertNotEqual(
            fcntl(installed, F_GETFD), -1,
            "the descriptor the retake installed was closed under it (errno \(errno))"
        )

        // And it really reaches the new child, not whatever else inherited the
        // number: the first child's sink must not grow.
        io.send(["type": "terminal.input", "bytes": "aGk="])
        waitUntil("the new child to receive the line") { spawner.sink(1).contains("terminal.input") }
        XCTAssertFalse(spawner.sink(0).contains("terminal.input"), "the write reached the released child")
        XCTAssertFalse(supervisor.isFinished, "a release and retake ended the bridge")
    }

    /// The whole point of the release: the bridge, and so the surface it is the
    /// PTY child of, outlives a child it asked to go away.
    func testAChildThatExitsWhileReleasedLeavesTheBridgeRunning() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let (supervisor, _) = makeSupervisor(spawner: spawner)

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.children[0].isRunning }
        // Long enough for a watcher that misread the exit to have finished.
        usleep(200_000)
        XCTAssertFalse(supervisor.isFinished)
        XCTAssertEqual(spawner.spawnCount, 1, "a release spawned a replacement")
    }

    /// The case that must still end the bridge: nothing asked the child to go.
    func testAChildThatExitsWhileHoldingFinishesTheBridgeWithItsStatus() {
        let spawner = Spawner(scripts: ["exit 7"])
        defer { spawner.terminateAll() }
        let (supervisor, _) = makeSupervisor(spawner: spawner)

        waitUntil("the bridge to finish") { supervisor.isFinished }
        XCTAssertEqual(supervisor.waitUntilFinished(), 7, "the child's own status is not what the bridge returns")
        XCTAssertEqual(spawner.spawnCount, 1, "a first child that could not attach was retried")
    }

    /// C2: herdr refuses an attach by shutting the connection down, so a
    /// retake's child can exit at once. That must not read as the pane dying,
    /// because the surface would then be frozen forever with nothing to rebuild
    /// it.
    func testARetakeHerdrRefusesIsRetriedAndNeverEndsTheBridge() {
        // The first child lingers; every retake is refused.
        let spawner = Spawner(scripts: ["cat > \"$SINK\"", "exit 1", "exit 1", "exit 1", "exit 1"])
        defer { spawner.terminateAll() }
        let status = Pipe()
        let delays = LockedBox([TimeInterval]())
        let (supervisor, _) = makeSupervisor(spawner: spawner, status: status, retries: delays)

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.children[0].isRunning }
        supervisor.handle(.take)

        waitUntil("the retries to run out") { delays.value.count == BridgeHoldState.takeRetryBackoff.count }
        usleep(300_000)
        XCTAssertFalse(supervisor.isFinished, "a refused retake ended the bridge and froze the surface")
        XCTAssertEqual(delays.value, BridgeHoldState.takeRetryBackoff)
        XCTAssertEqual(
            spawner.spawnCount, 2 + BridgeHoldState.takeRetryBackoff.count,
            "the take was not retried the bounded number of times"
        )

        let written = readAllAvailableForTest(status.fileHandleForReading.fileDescriptor)
        let lines = written.split(separator: 0x0A).filter { PaneStatusChannel.parseHoldLost(Data($0)) }
        XCTAssertEqual(lines.count, 1, "giving up said nothing the app could show")
    }

    /// I1: an EOF from a handle that is no longer installed decides nothing,
    /// even when paddock is holding again by the time it arrives.
    func testAStaleOutputEOFDoesNotEndTheBridge() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let (supervisor, _) = makeSupervisor(spawner: spawner)

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.children[0].isRunning }
        supervisor.handle(.take)
        waitUntil("the retake to spawn") { spawner.spawnCount == 2 }

        // The first child's output generation, replayed after the retake.
        supervisor.herdrOutputEnded(generation: 1)
        usleep(150_000)
        XCTAssertFalse(supervisor.isFinished, "a superseded handle's EOF ended the bridge")

        // The window the real race lives in: nothing installed yet.
        supervisor.herdrOutputEnded(generation: 0)
        usleep(100_000)
        XCTAssertFalse(supervisor.isFinished)
    }

    /// Only one child holds the pane at a time, so two clients can never race
    /// for one pane's lock.
    func testOnlyOneChildIsAliveAcrossTwoRoundTrips() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let (supervisor, _) = makeSupervisor(spawner: spawner)

        for round in 1...2 {
            supervisor.handle(.release)
            waitUntil("round \(round)'s child to exit") { !spawner.children[round - 1].isRunning }
            XCTAssertEqual(
                spawner.children.filter(\.isRunning).count, 0,
                "round \(round): a child outlived its release"
            )
            supervisor.handle(.take)
            waitUntil("round \(round)'s retake") { spawner.spawnCount == round + 1 }
            waitUntil("round \(round)'s new child to be running") { spawner.children[round].isRunning }
            XCTAssertEqual(
                spawner.children.filter(\.isRunning).count, 1,
                "round \(round): two children hold the pane at once"
            )
        }
        XCTAssertFalse(supervisor.isFinished)
        XCTAssertEqual(spawner.spawns, Array(repeating: PTYSize(cols: 80, rows: 24), count: 3))
    }

    /// A repeated command decides nothing, so a duplicated line cannot leave
    /// two children racing or none holding.
    func testRepeatedCommandsSpawnNothingExtra() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let (supervisor, _) = makeSupervisor(spawner: spawner)

        supervisor.handle(.take)
        XCTAssertEqual(spawner.spawnCount, 1, "a take for a pane already held spawned a second child")
        supervisor.handle(.release)
        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.children[0].isRunning }
        supervisor.handle(.take)
        waitUntil("the retake") { spawner.spawnCount == 2 }
        supervisor.handle(.take)
        usleep(100_000)
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    /// The PTY going away is final either way, which is what keeps a released
    /// bridge from outliving its surface.
    func testShutdownFinishesTheBridgeEvenWhileReleased() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let (supervisor, _) = makeSupervisor(spawner: spawner)

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.children[0].isRunning }
        XCTAssertFalse(supervisor.isFinished)

        supervisor.shutdown()
        waitUntil("the bridge to finish") { supervisor.isFinished }
        _ = supervisor.waitUntilFinished()
    }
}

/// File-local, like the same box in the other two bridge suites: each test
/// file keeps its own so none of them can be broken by a change made for
/// another.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
