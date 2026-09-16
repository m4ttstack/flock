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
        /// Process IDs, never the `Process` objects. Holding those here would
        /// keep every child's `Pipe` alive for the whole test, and a `Pipe`
        /// that never deallocates is exactly the thing whose deinit closes a
        /// descriptor the next child has already reclaimed. The supervisor's
        /// own reference has to be the only one, as it is in the bridge.
        private(set) var pids: [pid_t] = []
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
            pids.append(proc.processIdentifier)
            lock.unlock()
            return (proc, toChild.fileHandleForWriting, fromChild.fileHandleForReading)
        }

        var spawnCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return spawns.count
        }

        /// Reaped children answer ESRCH, which is what the supervisor's own
        /// `waitUntilExit` leaves behind.
        func isRunning(_ index: Int) -> Bool {
            lock.lock()
            guard index < pids.count else {
                lock.unlock()
                return false
            }
            let pid = pids[index]
            lock.unlock()
            return kill(pid, 0) == 0
        }

        var liveCount: Int {
            lock.lock()
            let all = pids
            lock.unlock()
            return all.filter { kill($0, 0) == 0 }.count
        }

        func sink(_ index: Int) -> String {
            lock.lock()
            let url = sinks[index]
            lock.unlock()
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        func terminateAll() {
            lock.lock()
            let all = pids
            let files = sinks
            lock.unlock()
            for pid in all { kill(pid, SIGKILL) }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// What `makeSupervisor` hands back: the pieces a test drives plus the
    /// output generation the first child was installed under, which is what an
    /// EOF has to carry to count as current.
    private struct Rig {
        let supervisor: BridgeChildSupervisor
        let io: BridgeIO
        let firstOutputGeneration: Int
    }

    /// A supervisor with its first child already spawned and its IO attached,
    /// wired the way `ControlBridge.run` wires them. `clock` lets a test age a
    /// child past `refusedTakeWindow` without waiting for it.
    private func makeSupervisor(
        spawner: Spawner,
        status: Pipe? = nil,
        retries: LockedBox<[TimeInterval]>? = nil,
        runRetries: Bool = true,
        clock: LockedBox<Date>? = nil,
        retryDelayInTest: TimeInterval = 0.01,
        afterRefusalObserved: @escaping () -> Void = {}
    ) -> Rig {
        let supervisor = BridgeChildSupervisor(
            ptySize: { PTYSize(cols: 80, rows: 24) },
            now: { clock?.value ?? Date() },
            scheduleRetry: { delay, work in
                retries?.mutate { $0.append(delay) }
                guard runRetries else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + retryDelayInTest, execute: work)
            },
            afterRefusalObserved: afterRefusalObserved,
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
        let generation = supervisor.installOutput(for: first!)
        supervisor.startWatching()
        return Rig(supervisor: supervisor, io: io, firstOutputGeneration: generation)
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

    /// The descriptor a retake installs is live and reaches the new child, with
    /// the previous one reaped and its pipe released. What makes the descriptor
    /// SAFE to hand over is tested directly, and deterministically, by
    /// `ControlBridgeTests.testSwappingAwayAnInputDoesNotLeaveItsPipeToClose...`;
    /// whether a freed number is reclaimed here is up to the runtime, so this
    /// covers the wiring rather than the ownership rule.
    func testARetakeInstallsALiveDescriptorThatReachesTheNewChild() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let rig = makeSupervisor(spawner: spawner)
        let (supervisor, io) = (rig.supervisor, rig.io)

        supervisor.handle(.release)
        waitUntil("the released child to exit") { spawner.spawnCount == 1 && !spawner.isRunning(0) }
        supervisor.handle(.take)
        waitUntil("the retake to spawn") { spawner.spawnCount == 2 }
        // The previous child is released in two steps (the supervisor's own
        // reference, then the watcher's), and it is the second that runs the
        // old pipe's deinit.
        usleep(200_000)

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
        let supervisor = makeSupervisor(spawner: spawner).supervisor

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.isRunning(0) }
        // Long enough for a watcher that misread the exit to have finished.
        usleep(200_000)
        XCTAssertFalse(supervisor.isFinished)
        XCTAssertEqual(spawner.spawnCount, 1, "a release spawned a replacement")
    }

    /// The case that must still end the bridge: nothing asked the child to go.
    func testAChildThatExitsWhileHoldingFinishesTheBridgeWithItsStatus() {
        let spawner = Spawner(scripts: ["exit 7"])
        defer { spawner.terminateAll() }
        let supervisor = makeSupervisor(spawner: spawner).supervisor

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
        let supervisor = makeSupervisor(spawner: spawner, status: status, retries: delays).supervisor

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.isRunning(0) }
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
    /// and the one from the installed handle still ends the bridge.
    ///
    /// The clock is advanced past `refusedTakeWindow` first, deliberately: with
    /// a young child every EOF reads `.refusedTake` and returns before the
    /// staleness check is reached, so the test would pass with that check
    /// deleted. Aged, the staleness check is the ONLY thing separating the two
    /// calls below.
    func testAStaleOutputEOFDecidesNothingAndTheCurrentOneEndsTheBridge() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let clock = LockedBox(Date())
        let rig = makeSupervisor(spawner: spawner, clock: clock)
        let supervisor = rig.supervisor

        clock.mutate { $0 = $0.addingTimeInterval(BridgeHoldState.refusedTakeWindow + 1) }

        supervisor.herdrOutputEnded(generation: rig.firstOutputGeneration + 99)
        usleep(150_000)
        XCTAssertFalse(supervisor.isFinished, "a superseded handle's EOF ended the bridge")

        // The window the real race lives in: a take has claimed the hold but
        // nothing is installed yet, so every generation is stale.
        supervisor.herdrOutputEnded(generation: 0)
        usleep(100_000)
        XCTAssertFalse(supervisor.isFinished)

        supervisor.herdrOutputEnded(generation: rig.firstOutputGeneration)
        waitUntil("the current handle's EOF to end the bridge") { supervisor.isFinished }
    }

    /// N5's half of the lost-status bug: a shutdown, not the watcher, is what
    /// finishes the bridge here, and the status still has to be the child's.
    /// The child traps SIGTERM and exits 7, so the ordering is forced rather
    /// than raced: `shutdown()` is the only thing that ends it.
    func testAShutdownStillReportsTheChildsOwnExitStatus() {
        let spawner = Spawner(scripts: ["trap 'exit 7' TERM; echo ready > \"$SINK\"; while true; do sleep 0.05; done"])
        defer { spawner.terminateAll() }
        let supervisor = makeSupervisor(spawner: spawner).supervisor
        waitUntil("the child to install its trap") { spawner.sink(0).contains("ready") }

        supervisor.shutdown()

        waitUntil("the bridge to finish") { supervisor.isFinished }
        XCTAssertEqual(
            supervisor.waitUntilFinished(), 7,
            "a shutdown reported its own nothing instead of the child's status"
        )
    }

    // MARK: - a release against a pending retry

    /// N1: while a retry is armed the bridge is already in the released state,
    /// so an app release arriving then has no hold to drop. It must still stop
    /// the retry, or a refused pane takes herdr's lock back behind an app that
    /// has let go, which is the very drift the intent reconciliation exists to
    /// prevent.
    func testAReleaseWhileARetryIsPendingStopsItFromTakingThePaneBack() {
        // The retake is refused once; the retry after it would succeed, so only
        // the release can stop it.
        let spawner = Spawner(scripts: ["cat > \"$SINK\"", "exit 1"])
        defer { spawner.terminateAll() }
        let delays = LockedBox([TimeInterval]())
        // Long enough for the release to land inside the armed window.
        let supervisor = makeSupervisor(
            spawner: spawner, retries: delays, retryDelayInTest: 0.5
        ).supervisor

        supervisor.handle(.release)
        waitUntil("the first child to exit") { !spawner.isRunning(0) }
        supervisor.handle(.take)
        waitUntil("the retake to be refused and a retry armed") { delays.value.count == 1 }

        supervisor.handle(.release)

        // Well past when the retry would have fired.
        usleep(900_000)
        XCTAssertEqual(spawner.spawnCount, 2, "the cancelled retry spawned a herdr client anyway")
        XCTAssertEqual(spawner.liveCount, 0, "a child is holding the pane after a release")
        XCTAssertEqual(delays.value.count, 1, "the cancelled retry armed another one")
        XCTAssertFalse(supervisor.isFinished)
    }

    /// The other order: the release lands first and the take that follows is
    /// the app's own, so it must go through. A cancelled retry must not poison
    /// the next real take.
    func testATakeAfterAReleaseThatCancelledARetryStillWorks() {
        let spawner = Spawner(scripts: ["cat > \"$SINK\"", "exit 1"])
        defer { spawner.terminateAll() }
        let delays = LockedBox([TimeInterval]())
        let supervisor = makeSupervisor(
            spawner: spawner, retries: delays, retryDelayInTest: 0.5
        ).supervisor

        supervisor.handle(.release)
        waitUntil("the first child to exit") { !spawner.isRunning(0) }
        supervisor.handle(.take)
        waitUntil("a retry to be armed") { delays.value.count == 1 }
        supervisor.handle(.release)
        usleep(700_000)

        supervisor.handle(.take)
        waitUntil("the app's own take to spawn") { spawner.spawnCount == 3 }
        waitUntil("its child to be running") { spawner.isRunning(2) }
        XCTAssertEqual(spawner.liveCount, 1)
        XCTAssertFalse(supervisor.isFinished)
    }

    /// The narrow residual of the same finding: a release landing between a
    /// refusal being classified and the retry being armed. Re-reading the epoch
    /// at arming time would adopt that release's own epoch as the retry's
    /// baseline, so the retry would pass its check when it fired and retake the
    /// pane behind an app that had genuinely let go. Carrying the epoch from
    /// the attempt that failed is what closes it.
    ///
    /// The window is a few instructions wide, so the release is landed inside
    /// it through the supervisor's own `afterRefusalObserved` seam rather than
    /// by racing it.
    func testAReleaseLandingBetweenTheRefusalAndTheRetryStillCancelsIt() {
        // The retake is refused; the retry after it would succeed, so only a
        // correctly cancelled retry keeps the pane released.
        let spawner = Spawner(scripts: ["cat > \"$SINK\"", "exit 1"])
        defer { spawner.terminateAll() }
        let status = Pipe()
        let delays = LockedBox([TimeInterval]())
        let released = LockedBox(false)
        let holder = LockedBox<BridgeChildSupervisor?>(nil)
        let rig = makeSupervisor(
            spawner: spawner, status: status, retries: delays, retryDelayInTest: 0.2,
            afterRefusalObserved: {
                // Once, and only for the refusal this test is about.
                guard !released.value else { return }
                released.mutate { $0 = true }
                holder.value?.handle(.release)
            }
        )
        holder.mutate { $0 = rig.supervisor }
        let supervisor = rig.supervisor

        supervisor.handle(.release)
        waitUntil("the first child to exit") { !spawner.isRunning(0) }
        supervisor.handle(.take)

        waitUntil("the refusal to be observed") { released.value }
        // Well past when a retry, had one been armed, would have fired.
        usleep(800_000)

        XCTAssertEqual(delays.value, [], "a retry was armed against the release's own epoch")
        XCTAssertEqual(spawner.spawnCount, 2, "the retry spawned a herdr client after the release")
        XCTAssertEqual(spawner.liveCount, 0, "a child is holding the pane after a release")
        XCTAssertFalse(supervisor.isFinished)
        // The pane has no herdr client because the app asked for that, not
        // because the bridge gave up on it. Guaranteed twice over, since the
        // release also resets the retry budget, so this cannot be the
        // assertion that catches a missing epoch guard.
        let written = readAllAvailableForTest(status.fileHandleForReading.fileDescriptor)
        let lost = written.split(separator: 0x0A).filter { PaneStatusChannel.parseHoldLost(Data($0)) }
        XCTAssertEqual(lost.count, 0, "a pane the app released was marked as having lost its hold")
    }

    /// The app's own take carries no epoch, so `finished` is the only thing
    /// standing between a `paddock.take_hold` that arrives after the bridge is
    /// done and a wasted herdr client. Released first, deliberately: a bridge
    /// that still holds would refuse the take on `hold.take()` alone and the
    /// guard under test would never be reached.
    func testAnAppTakeAfterShutdownSpawnsNothing() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let supervisor = makeSupervisor(spawner: spawner).supervisor

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.isRunning(0) }
        supervisor.shutdown()
        waitUntil("the bridge to finish") { supervisor.isFinished }

        supervisor.handle(.take)
        usleep(300_000)
        XCTAssertEqual(spawner.spawnCount, 1, "a take after shutdown spawned a herdr client")
        XCTAssertEqual(spawner.liveCount, 0, "a child outlived the bridge")
    }

    /// A shutdown has to stop a pending retry too, or the bridge exits with a
    /// herdr client it spawned on the way out.
    func testAShutdownWhileARetryIsPendingSpawnsNothingFurther() {
        let spawner = Spawner(scripts: ["cat > \"$SINK\"", "exit 1"])
        defer { spawner.terminateAll() }
        let delays = LockedBox([TimeInterval]())
        let supervisor = makeSupervisor(
            spawner: spawner, retries: delays, retryDelayInTest: 0.5
        ).supervisor

        supervisor.handle(.release)
        waitUntil("the first child to exit") { !spawner.isRunning(0) }
        supervisor.handle(.take)
        waitUntil("a retry to be armed") { delays.value.count == 1 }

        supervisor.shutdown()
        usleep(900_000)

        XCTAssertTrue(supervisor.isFinished)
        XCTAssertEqual(spawner.spawnCount, 2, "a retry spawned a child after the bridge was finished")
        XCTAssertEqual(spawner.liveCount, 0, "a child outlived the bridge")
    }

    /// Only one child holds the pane at a time, so two clients can never race
    /// for one pane's lock.
    func testOnlyOneChildIsAliveAcrossTwoRoundTrips() {
        let spawner = Spawner(scripts: [])
        defer { spawner.terminateAll() }
        let supervisor = makeSupervisor(spawner: spawner).supervisor

        for round in 1...2 {
            supervisor.handle(.release)
            waitUntil("round \(round)'s child to exit") { !spawner.isRunning(round - 1) }
            XCTAssertEqual(
                spawner.liveCount, 0,
                "round \(round): a child outlived its release"
            )
            supervisor.handle(.take)
            waitUntil("round \(round)'s retake") { spawner.spawnCount == round + 1 }
            waitUntil("round \(round)'s new child to be running") { spawner.isRunning(round) }
            XCTAssertEqual(
                spawner.liveCount, 1,
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
        let supervisor = makeSupervisor(spawner: spawner).supervisor

        supervisor.handle(.take)
        XCTAssertEqual(spawner.spawnCount, 1, "a take for a pane already held spawned a second child")
        supervisor.handle(.release)
        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.isRunning(0) }
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
        let supervisor = makeSupervisor(spawner: spawner).supervisor

        supervisor.handle(.release)
        waitUntil("the released child to exit") { !spawner.isRunning(0) }
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
