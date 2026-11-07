import XCTest
@testable import FlockCore

@MainActor
final class MachineTunnelTests: XCTestCase {
    private final class FakeChild: MachineTunnelChild, @unchecked Sendable {
        let exited: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        private(set) var terminated = false

        init() {
            (exited, continuation) = AsyncStream.makeStream()
        }

        func exit(_ line: String) {
            continuation.yield(line)
            continuation.finish()
        }

        func terminate() {
            terminated = true
        }
    }

    @MainActor
    private final class Rig {
        static let remoteSocket = "/Users/acme/.config/herdr/herdr.sock"
        let machine = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")
        let paths = MachineTunnelPaths(uid: 501, bundleTag: "dev", machineID: "0123456789abcdef0123456789abcdef")

        var resolveError: Error?
        var resolveCount = 0
        var holdsResolve = false
        var heldResolve: CheckedContinuation<Void, Never>?
        var holdsProbe = false
        var heldProbes: [CheckedContinuation<Void, Never>] = []
        var launches: [[String]] = []
        var children: [FakeChild] = []
        var probeAnswer = false
        var probed: [String] = []
        var prepared: [String] = []
        var removed: [String] = []
        var delay: Duration = .zero
        var backoffs: [(attempt: Int, state: MachineTunnelState?)] = []
        weak var tunnel: MachineTunnel?

        func makeTunnel(probeInterval: Duration = .milliseconds(100), connectTimeout: Duration = .seconds(10)) -> MachineTunnel {
            let tunnel = MachineTunnel(
                machine: machine,
                paths: paths,
                resolve: { _ in
                    self.resolveCount += 1
                    if self.holdsResolve {
                        await withCheckedContinuation { self.heldResolve = $0 }
                    }
                    if let error = self.resolveError { throw error }
                    return Rig.remoteSocket
                },
                launch: { arguments in
                    self.launches.append(arguments)
                    let child = FakeChild()
                    self.children.append(child)
                    return child
                },
                probe: { path in
                    self.probed.append(path)
                    if self.holdsProbe {
                        await withCheckedContinuation { self.heldProbes.append($0) }
                    }
                    return self.probeAnswer
                },
                prepareDirectory: { self.prepared.append($0) },
                removeDirectory: { self.removed.append($0) },
                backoff: { attempt in
                    self.backoffs.append((attempt, self.tunnel?.state))
                    return self.delay
                },
                probeInterval: probeInterval,
                connectTimeout: connectTimeout
            )
            self.tunnel = tunnel
            return tunnel
        }
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("condition never held", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func testStartResolvesLaunchesAndGoesUpWhenProbeAnswers() async {
        let rig = Rig()
        rig.probeAnswer = true
        let tunnel = rig.makeTunnel()
        tunnel.start()
        XCTAssertEqual(tunnel.state, .connecting)

        await waitUntil { tunnel.state == .up }
        XCTAssertEqual(rig.resolveCount, 1)
        XCTAssertEqual(rig.prepared, [rig.paths.directory])
        XCTAssertEqual(rig.launches, [MachineSSH.forwardArguments(target: "acme-mini", paths: rig.paths, remoteAPISocket: Rig.remoteSocket)])
        XCTAssertEqual(rig.probed.first, rig.paths.apiSocket)
        await tunnel.stop()
    }

    func testSshExitMovesToUnreachableWithStderrThenRestarts() async {
        let rig = Rig()
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.children.count == 1 }

        rig.children[0].exit("Connection refused")
        await waitUntil { rig.launches.count == 2 }
        XCTAssertEqual(rig.backoffs.map(\.attempt), [1])
        XCTAssertEqual(rig.backoffs.first?.state, .unreachable(reason: "Connection refused"))
        await tunnel.stop()
    }

    func testRetryKeepsShowingTheLastFailure() async {
        let rig = Rig()
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.children.count == 1 }

        rig.children[0].exit("Connection refused")
        await waitUntil { rig.launches.count == 2 }
        XCTAssertEqual(tunnel.state, .unreachable(reason: "Connection refused"))

        rig.probeAnswer = true
        await waitUntil { tunnel.state == .up }
        await tunnel.stop()
    }

    func testRetryResolvingAfterNoServerStillShowsNoServer() async {
        let rig = Rig()
        rig.resolveError = MachineResolveError.noServer
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { tunnel.state == .noServer }

        rig.holdsResolve = true
        await waitUntil { rig.heldResolve != nil }
        XCTAssertEqual(tunnel.state, .noServer)
        await tunnel.stop()
        rig.heldResolve?.resume()
    }

    func testEmptyStderrReadsAsGenericExit() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.children.count == 1 }

        rig.children[0].exit("")
        await waitUntil { tunnel.state == .unreachable(reason: "ssh exited.") }
        await tunnel.stop()
    }

    func testResolveFailureIsUnreachableAndNeverLaunches() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        rig.resolveError = MachineResolveError.failed("ssh: Could not resolve hostname acme-mini")
        let tunnel = rig.makeTunnel()
        tunnel.start()

        await waitUntil { rig.backoffs.count == 1 }
        XCTAssertEqual(tunnel.state, .unreachable(reason: "ssh: Could not resolve hostname acme-mini"))
        XCTAssertEqual(rig.launches, [])
        XCTAssertEqual(rig.prepared, [])
        await tunnel.stop()
    }

    func testUnknownSessionNamesTheSessionAndMachine() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        rig.resolveError = MachineResolveError.unknownSession
        let tunnel = rig.makeTunnel()
        tunnel.start()

        await waitUntil { rig.backoffs.count == 1 }
        XCTAssertEqual(tunnel.state, .unreachable(reason: "herdr has no session named default on acme-mini."))
        await tunnel.stop()
    }

    func testStopDuringResolveNeverLaunches() async {
        let rig = Rig()
        rig.holdsResolve = true
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.heldResolve != nil }

        await tunnel.stop()
        rig.heldResolve?.resume()
        await settle()
        XCTAssertEqual(rig.prepared, [])
        XCTAssertEqual(rig.launches, [])
        XCTAssertEqual(rig.backoffs.count, 0)
        XCTAssertEqual(tunnel.state, .stopped)
    }

    func testNoRemoteServerIsNoServerState() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        rig.resolveError = MachineResolveError.noServer
        let tunnel = rig.makeTunnel()
        tunnel.start()

        await waitUntil { rig.backoffs.count == 1 }
        XCTAssertEqual(tunnel.state, .noServer)
        XCTAssertEqual(rig.launches, [])
        await tunnel.stop()
    }

    func testResolveRetriesAfterFailure() async {
        let rig = Rig()
        rig.resolveError = MachineResolveError.noServer
        rig.probeAnswer = true
        let tunnel = rig.makeTunnel()
        rig.delay = .milliseconds(20)
        tunnel.start()

        await waitUntil { tunnel.state == .noServer }
        rig.resolveError = nil
        await waitUntil { tunnel.state == .up }
        XCTAssertEqual(rig.launches.count, 1)
        await tunnel.stop()
    }

    func testStopTerminatesChildRemovesDirectoryAndStaysStopped() async {
        let rig = Rig()
        rig.probeAnswer = true
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { tunnel.state == .up }

        await tunnel.stop()
        XCTAssertTrue(rig.children[0].terminated)
        XCTAssertEqual(rig.removed, [rig.paths.directory])
        XCTAssertEqual(tunnel.state, .stopped)

        rig.children[0].exit("Connection closed")
        await settle()
        XCTAssertEqual(rig.launches.count, 1)
        XCTAssertEqual(rig.backoffs.count, 0)
        XCTAssertEqual(tunnel.state, .stopped)
    }

    func testStopWhileWaitingOutBackoffNeverRestarts() async {
        let rig = Rig()
        rig.delay = .milliseconds(30)
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.children.count == 1 }
        rig.children[0].exit("Connection refused")
        await waitUntil { rig.backoffs.count == 1 }

        await tunnel.stop()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(rig.launches.count, 1)
        XCTAssertEqual(tunnel.state, .stopped)
    }

    func testEarlyExitReResolvesOnce() async {
        let rig = Rig()
        let tunnel = rig.makeTunnel()
        tunnel.start()

        for round in 1...3 {
            await waitUntil { rig.children.count == round }
            rig.children[round - 1].exit("Connection refused")
        }
        await waitUntil { rig.launches.count == 4 }
        XCTAssertEqual(rig.resolveCount, 2)
        await tunnel.stop()
    }

    func testExitAfterUpKeepsResolvedSocket() async {
        let rig = Rig()
        rig.probeAnswer = true
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { tunnel.state == .up }

        rig.children[0].exit("Connection closed by remote host")
        await waitUntil { rig.launches.count == 2 }
        XCTAssertEqual(rig.resolveCount, 1)
        await tunnel.stop()
    }

    func testAttemptCountsConsecutiveFailuresAndResetsAfterUp() async {
        let rig = Rig()
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.children.count == 1 }
        rig.children[0].exit("Connection refused")
        await waitUntil { rig.children.count == 2 }
        rig.children[1].exit("Connection refused")
        await waitUntil { rig.children.count == 3 }

        rig.probeAnswer = true
        await waitUntil { tunnel.state == .up }
        rig.children[2].exit("Connection closed")
        await waitUntil { rig.children.count == 4 }
        XCTAssertEqual(rig.backoffs.map(\.attempt), [1, 2, 1])
        await tunnel.stop()
    }

    func testProbeTimeoutTerminatesChildAndRestarts() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        let tunnel = rig.makeTunnel(probeInterval: .milliseconds(1), connectTimeout: .milliseconds(20))
        tunnel.start()

        await waitUntil { rig.backoffs.count == 1 }
        XCTAssertTrue(rig.children[0].terminated)
        XCTAssertEqual(tunnel.state, .unreachable(reason: "Timed out connecting."))
        await tunnel.stop()
    }

    func testHungProbeStillTimesOut() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        rig.holdsProbe = true
        let tunnel = rig.makeTunnel(connectTimeout: .milliseconds(20))
        tunnel.start()

        await waitUntil { rig.backoffs.count == 1 }
        XCTAssertTrue(rig.children[0].terminated)
        XCTAssertEqual(tunnel.state, .unreachable(reason: "Timed out connecting."))
        await tunnel.stop()
        rig.heldProbes.forEach { $0.resume() }
    }

    func testHungProbeDoesNotHoldUpAnExit() async {
        let rig = Rig()
        rig.delay = .seconds(60)
        rig.holdsProbe = true
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { rig.heldProbes.count == 1 }

        rig.children[0].exit("Connection refused")
        await waitUntil { rig.backoffs.count == 1 }
        XCTAssertEqual(tunnel.state, .unreachable(reason: "Connection refused"))
        await tunnel.stop()
        rig.heldProbes.forEach { $0.resume() }
    }

    func testStopNowTerminatesWithoutAwaiting() async {
        let rig = Rig()
        rig.probeAnswer = true
        let tunnel = rig.makeTunnel()
        tunnel.start()
        await waitUntil { tunnel.state == .up }

        tunnel.stopNow()
        XCTAssertTrue(rig.children[0].terminated)
        XCTAssertEqual(rig.removed, [rig.paths.directory])
        XCTAssertEqual(tunnel.state, .stopped)
    }

    func testBackoffSchedule() {
        XCTAssertEqual((1...7).map(MachineTunnel.defaultBackoff), [1, 2, 4, 8, 15, 15, 15].map { .seconds($0) })
    }
}
