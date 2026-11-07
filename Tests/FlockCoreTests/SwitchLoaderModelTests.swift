import XCTest
@testable import FlockCore

final class SwitchLoaderModelTests: XCTestCase {
    private let label = "acme-mini"

    private func machine(
        _ tunnel: MachineTunnelState, _ store: ConnectionState, grace: Bool = false, removed: Bool = false,
        isDefault: Bool = false
    ) -> SwitchLoaderModel? {
        SwitchLoaderModel.make(SwitchLoaderInput(
            label: label, isMachine: true, isDefaultProfile: isDefault, tunnel: tunnel, store: store,
            tunnelUpGraceActive: grace, currentMachineMissing: removed
        ))
    }

    private func local(_ store: ConnectionState, switching: Bool, label: String = "Work") -> SwitchLoaderModel? {
        SwitchLoaderModel.make(SwitchLoaderInput(
            label: label, isMachine: false, isDefaultProfile: label == "Default", store: store, isSwitching: switching
        ))
    }

    private let allStores: [ConnectionState] = [
        .connecting, .live, .reconnecting(attempt: 2), .notRunning(attempt: 1), .unsupported(.protocolTooOld(found: 1, required: 2)),
    ]

    private var connectingToMachine: SwitchLoaderModel {
        SwitchLoaderModel(phase: .working, title: "Switching to acme-mini", status: "Connecting to acme-mini\u{2026}", showsSwitchToDefault: false)
    }

    private var attachingToMachine: SwitchLoaderModel {
        SwitchLoaderModel(phase: .working, title: "Switching to acme-mini", status: "Attaching", showsSwitchToDefault: false)
    }

    private var machineNotRunning: SwitchLoaderModel {
        SwitchLoaderModel(
            phase: .failed, title: "herdr isn't running on acme-mini.",
            status: "Start herdr on acme-mini and Flock will attach.", showsSwitchToDefault: true
        )
    }

    private var done: SwitchLoaderModel {
        SwitchLoaderModel(phase: .done, title: "Switching to acme-mini", status: "Attaching", showsSwitchToDefault: false)
    }

    func testAConnectingOrUnstartedTunnelReadsAsConnectingWhateverTheStoreSays() {
        for tunnel: MachineTunnelState in [.connecting, .stopped] {
            for store in allStores where store != .live {
                XCTAssertEqual(machine(tunnel, store), connectingToMachine, "\(tunnel) \(store)")
            }
        }
    }

    func testAnUpTunnelIsAttachingUntilTheStoreAnswers() {
        XCTAssertEqual(machine(.up, .connecting), attachingToMachine)
        XCTAssertEqual(machine(.up, .reconnecting(attempt: 1), grace: true), attachingToMachine)
        XCTAssertEqual(machine(.up, .notRunning(attempt: 1), grace: true), attachingToMachine)
    }

    func testAnUpTunnelWithNoStorePastTheGraceIsHerdrNotRunning() {
        XCTAssertEqual(machine(.up, .reconnecting(attempt: 3)), machineNotRunning)
        XCTAssertEqual(machine(.up, .notRunning(attempt: 1)), machineNotRunning)
    }

    func testNoServerIsHerdrNotRunningEvenInTheGrace() {
        for store in allStores where store != .live {
            XCTAssertEqual(machine(.noServer, store), machineNotRunning, "\(store)")
            XCTAssertEqual(machine(.noServer, store, grace: true), machineNotRunning, "\(store)")
        }
    }

    func testUnreachableSplitsTheBannerIntoTitleAndReason() {
        XCTAssertEqual(
            machine(.unreachable(reason: "Permission denied (publickey)."), .reconnecting(attempt: 1)),
            SwitchLoaderModel(
                phase: .failed, title: "Can't reach acme-mini.",
                status: "Permission denied (publickey). If your key has a passphrase, run ssh-add, then check that ssh acme-mini works.",
                showsSwitchToDefault: true
            )
        )
        XCTAssertEqual(
            machine(.unreachable(reason: "Host key verification failed."), .notRunning(attempt: 1))?.status,
            "Host key verification failed. Run ssh acme-mini once in Terminal, then add its host key to known_hosts."
        )
        XCTAssertEqual(machine(.unreachable(reason: "Connection refused"), .connecting)?.status, "Connection refused.")
        XCTAssertEqual(machine(.unreachable(reason: "ssh exited."), .connecting)?.title, "Can't reach acme-mini.")
    }

    func testARemovedMachineOutranksTheConnection() {
        let removed = SwitchLoaderModel(
            phase: .failed, title: "acme-mini is no longer a saved herdr machine.",
            status: "Pick another profile, or switch to Default.", showsSwitchToDefault: true
        )
        let tunnels: [MachineTunnelState] = [.stopped, .connecting, .up, .noServer, .unreachable(reason: "ssh exited.")]
        for tunnel in tunnels {
            for store in allStores where store != .live {
                XCTAssertEqual(machine(tunnel, store, removed: true), removed, "\(tunnel) \(store)")
            }
        }
    }

    func testALiveStoreIsDoneWhateverElseIsTrue() {
        let tunnels: [MachineTunnelState] = [.stopped, .connecting, .up, .noServer, .unreachable(reason: "ssh exited.")]
        for tunnel in tunnels {
            XCTAssertEqual(machine(tunnel, .live), done, "\(tunnel)")
            XCTAssertEqual(machine(tunnel, .live, removed: true), done, "\(tunnel)")
        }
        XCTAssertEqual(machine(.up, .unsupported(.protocolTooOld(found: 1, required: 2))), done)
    }

    func testTheDefaultProfileNeverOffersToSwitchToItself() {
        XCTAssertEqual(machine(.noServer, .notRunning(attempt: 1), isDefault: true)?.showsSwitchToDefault, false)
        XCTAssertEqual(machine(.unreachable(reason: "x"), .connecting, isDefault: true)?.showsSwitchToDefault, false)
        XCTAssertEqual(machine(.connecting, .connecting, removed: true, isDefault: true)?.showsSwitchToDefault, false)
    }

    func testOnlyFailuresOfferTheButton() {
        XCTAssertEqual(machine(.connecting, .connecting)?.showsSwitchToDefault, false)
        XCTAssertEqual(machine(.up, .connecting)?.showsSwitchToDefault, false)
    }

    func testALocalSwitchAttachesUntilLive() {
        let attaching = SwitchLoaderModel(phase: .working, title: "Switching to Work", status: "Attaching", showsSwitchToDefault: false)
        XCTAssertEqual(local(.connecting, switching: true), attaching)
        XCTAssertEqual(local(.reconnecting(attempt: 1), switching: true), attaching)
        XCTAssertEqual(local(.live, switching: true)?.phase, .done)
        XCTAssertEqual(local(.unsupported(.protocolTooOld(found: 1, required: 2)), switching: true)?.phase, .done)
        XCTAssertEqual(local(.connecting, switching: true, label: "Default")?.title, "Switching to Default")
    }

    func testALocalServerThatIsNotRunningBelongsToTheNoHerdrScreen() {
        XCTAssertNil(local(.notRunning(attempt: 1), switching: true))
    }

    func testALocalProfileThatIsNotSwitchingHasNoLoader() {
        for store in allStores {
            XCTAssertNil(local(store, switching: false), "\(store)")
        }
    }
}
