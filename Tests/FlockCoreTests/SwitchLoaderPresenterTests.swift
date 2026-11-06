import XCTest
@testable import FlockCore

@MainActor
final class SwitchLoaderPresenterTests: XCTestCase {
    private final class Clock {
        var time: Double = 1000
    }

    private func makePresenter(_ clock: Clock) -> SwitchLoaderPresenter {
        SwitchLoaderPresenter(now: { clock.time }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
    }

    private func machine(
        _ tunnel: MachineTunnelState, _ store: ConnectionState, pending: Bool = false, generation: Int = 0,
        label: String = "acme-mini"
    ) -> SwitchLoaderPresenter.Snapshot {
        .init(
            input: SwitchLoaderInput(label: label, isMachine: true, isDefaultProfile: false, tunnel: tunnel, store: store),
            switchPending: pending, generation: generation
        )
    }

    private func local(
        _ store: ConnectionState, pending: Bool = false, generation: Int = 0, label: String = "Work"
    ) -> SwitchLoaderPresenter.Snapshot {
        .init(
            input: SwitchLoaderInput(label: label, isMachine: false, isDefaultProfile: label == "Default", store: store),
            switchPending: pending, generation: generation
        )
    }

    func testAMachineSessionThatHasNotBeenLiveIsCovered() {
        let presenter = makePresenter(Clock())
        presenter.update(machine(.stopped, .connecting))
        XCTAssertEqual(presenter.run?.title.current, "Switching to acme-mini")
        XCTAssertEqual(presenter.run?.status.current, "Connecting to acme-mini\u{2026}")
    }

    func testALocalSessionAtLaunchIsNotCovered() {
        let presenter = makePresenter(Clock())
        presenter.update(local(.connecting))
        XCTAssertNil(presenter.run)
    }

    func testALiveMachineFinishesTheRunAndAMidSessionDropKeepsTheWindow() {
        let clock = Clock()
        let presenter = makePresenter(clock)
        presenter.update(machine(.connecting, .connecting))
        clock.time += 0.3
        presenter.update(machine(.up, .live))
        XCTAssertEqual(presenter.run?.isFinishing, true)
        XCTAssertFalse(presenter.coversWindow)

        let after = makePresenter(clock)
        after.update(machine(.up, .live))
        after.update(machine(.unreachable(reason: "ssh exited."), .reconnecting(attempt: 1)))
        XCTAssertNil(after.run, "the title bar notice covers a drop while panes stay up")
        after.update(machine(.up, .notRunning(attempt: 2)))
        XCTAssertEqual(after.run?.title.current, "herdr isn't running on acme-mini.")
    }

    func testALocalSwitchIsCoveredFromItsStartAcrossTheRebuildUntilLive() {
        let clock = Clock()
        let presenter = makePresenter(clock)
        presenter.update(local(.live, generation: 0, label: "Work"))
        XCTAssertNil(presenter.run)

        presenter.update(local(.connecting, pending: true, generation: 0, label: "Default"))
        let id = presenter.run?.id
        XCTAssertEqual(presenter.run?.title.current, "Switching to Default")
        XCTAssertEqual(presenter.run?.status.current, "Attaching")

        clock.time += 0.4
        presenter.update(local(.connecting, generation: 1, label: "Default"))
        XCTAssertEqual(presenter.run?.id, id, "the rebuild carries the run")
        XCTAssertEqual(presenter.run?.isFinishing, false)

        clock.time += 0.2
        presenter.update(local(.live, generation: 1, label: "Default"))
        XCTAssertEqual(presenter.run?.isFinishing, true)
        XCTAssertEqual(presenter.run?.finishAt ?? -1, SwitchLoaderRun.Timing.breath, accuracy: 1e-9)
    }

    func testAPendingSwitchIsCoveredAtOnce() {
        let presenter = makePresenter(Clock())
        presenter.update(machine(.connecting, .connecting, pending: true, generation: 0))
        XCTAssertEqual(presenter.run?.isFinishing, false)
    }

    func testALocalSwitchOntoAStoppedServerHandsOverToTheNoHerdrScreen() {
        let clock = Clock()
        let presenter = makePresenter(clock)
        presenter.update(local(.connecting, pending: true, label: "Default"))
        clock.time += 0.5
        presenter.update(local(.notRunning(attempt: 1), generation: 1, label: "Default"))
        XCTAssertEqual(presenter.run?.isFinishing, true)
        XCTAssertEqual(presenter.run?.finishAt ?? -1, 0.5, accuracy: 1e-9)
    }

    func testAFailingMachineSwitchingAwayCrossfadesToTheTarget() {
        let clock = Clock()
        let presenter = makePresenter(clock)
        presenter.update(machine(.unreachable(reason: "ssh exited."), .connecting))
        XCTAssertEqual(presenter.run?.phase, .failed)
        let id = presenter.run?.id
        clock.time += 3
        presenter.update(local(.connecting, pending: true, label: "Default"))
        XCTAssertEqual(presenter.run?.id, id)
        XCTAssertEqual(presenter.run?.phase, .working)
        XCTAssertEqual(presenter.run?.title.current, "Switching to Default")
        XCTAssertEqual(presenter.run?.title.previous, "Can't reach acme-mini.")
    }

    func testANewSwitchDuringTheFadeStartsANewRun() {
        let clock = Clock()
        let presenter = makePresenter(clock)
        presenter.update(local(.connecting, pending: true))
        presenter.update(local(.live, generation: 1))
        let first = presenter.run?.id
        XCTAssertEqual(presenter.run?.isFinishing, true)
        presenter.update(machine(.connecting, .connecting, pending: true, generation: 1))
        XCTAssertNotEqual(presenter.run?.id, first)
        XCTAssertEqual(presenter.run?.isFinishing, false)
    }

    func testTheRunEndsAndUncoversWhenItsTimersFire() async {
        let presenter = SwitchLoaderPresenter(now: { 0 }, sleep: { _ in await Task.yield() })
        presenter.update(machine(.connecting, .connecting))
        for _ in 0..<20 where !presenter.coversWindow { await Task.yield() }
        XCTAssertTrue(presenter.coversWindow)
        presenter.update(machine(.up, .live))
        XCTAssertFalse(presenter.coversWindow)
        for _ in 0..<20 where presenter.run != nil { await Task.yield() }
        XCTAssertNil(presenter.run)
    }

    func testAFailureSettlesSoTheClockCanStop() async {
        let presenter = SwitchLoaderPresenter(now: { 0 }, sleep: { _ in await Task.yield() })
        presenter.update(machine(.noServer, .notRunning(attempt: 1)))
        for _ in 0..<20 where !presenter.isSettled { await Task.yield() }
        XCTAssertTrue(presenter.isSettled)
        presenter.update(machine(.up, .connecting))
        XCTAssertFalse(presenter.isSettled)
    }
}
