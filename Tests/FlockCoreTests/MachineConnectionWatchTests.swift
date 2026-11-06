import XCTest
@testable import FlockCore

@MainActor
final class MachineConnectionWatchTests: XCTestCase {
    private final class FakeChild: MachineTunnelChild, @unchecked Sendable {
        let exited: AsyncStream<String>
        init() { (exited, _) = AsyncStream.makeStream() }
        func terminate() {}
    }

    /// A sleep that returns only when the test lets it.
    private final class GatedSleep: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private var storedRequested: [Duration] = []

        func sleep(_ duration: Duration) async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    storedRequested.append(duration)
                    waiters.append(continuation)
                }
            }
        }

        var requested: [Duration] { lock.withLock { storedRequested } }

        func release() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { waiters = [] }
                return waiters
            }
            all.forEach { $0.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline { return XCTFail("timed out", line: line) }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func makeStore() -> HerdrStore {
        HerdrStore(socketPath: "/tmp/pdhs-watch-no-such.sock", backoffSchedule: { _ in .seconds(600) })
    }

    private func makeTunnel(probeAnswer: Bool) -> MachineTunnel {
        let machine = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")
        return MachineTunnel(
            machine: machine,
            paths: MachineTunnelPaths(uid: 501, bundleTag: "test", machineID: machine.id),
            resolve: { _ in "/Users/acme/.config/herdr/herdr.sock" },
            launch: { _ in FakeChild() },
            probe: { _ in probeAnswer },
            prepareDirectory: { _ in },
            removeDirectory: { _ in }
        )
    }

    private func makeWatch(_ gate: GatedSleep, tunnel: MachineTunnel? = nil) -> MachineConnectionWatch {
        MachineConnectionWatch(
            tunnel: tunnel ?? makeTunnel(probeAnswer: false), store: makeStore(), grace: .seconds(5), sleep: gate.sleep
        )
    }

    func testGraceStartsWhenTheTunnelComesUpAndEndsAfterTheWindow() async {
        let gate = GatedSleep()
        let watch = makeWatch(gate)
        watch.handle(tunnel: .connecting, store: .connecting)
        XCTAssertFalse(watch.graceActive)

        watch.handle(tunnel: .up, store: .notRunning(attempt: 1))
        XCTAssertTrue(watch.graceActive)
        await waitUntil { gate.requested == [.seconds(5)] }

        gate.release()
        await waitUntil { !watch.graceActive }
    }

    func testGraceEndsWhenTheStoreGoesLive() {
        let watch = makeWatch(GatedSleep())
        watch.handle(tunnel: .up, store: .notRunning(attempt: 1))
        XCTAssertTrue(watch.graceActive)
        watch.handle(tunnel: .up, store: .live)
        XCTAssertFalse(watch.graceActive)
    }

    func testALaterStoreDropWithTheTunnelStillUpGetsNoGrace() {
        let watch = makeWatch(GatedSleep())
        watch.handle(tunnel: .up, store: .notRunning(attempt: 1))
        watch.handle(tunnel: .up, store: .live)
        watch.handle(tunnel: .up, store: .reconnecting(attempt: 1))
        XCTAssertFalse(watch.graceActive)
    }

    func testGraceEndsWhenTheTunnelLeavesUpAndRestartsOnTheNextUp() {
        let watch = makeWatch(GatedSleep())
        watch.handle(tunnel: .up, store: .notRunning(attempt: 1))
        watch.handle(tunnel: .connecting, store: .notRunning(attempt: 1))
        XCTAssertFalse(watch.graceActive)

        watch.handle(tunnel: .up, store: .notRunning(attempt: 2))
        XCTAssertTrue(watch.graceActive)
    }

    func testObservingARealTunnelStartsTheGraceWhenItReportsUp() async {
        let gate = GatedSleep()
        let tunnel = makeTunnel(probeAnswer: true)
        let watch = makeWatch(gate, tunnel: tunnel)
        watch.start()
        XCTAssertFalse(watch.graceActive)
        tunnel.start()

        await waitUntil { tunnel.state == .up }
        await waitUntil { watch.graceActive }
        await waitUntil { !gate.requested.isEmpty }
        gate.release()
        await waitUntil { !watch.graceActive }

        watch.stop()
        await tunnel.stop()
    }
}
