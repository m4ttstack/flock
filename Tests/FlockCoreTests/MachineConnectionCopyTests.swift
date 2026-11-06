import XCTest
@testable import FlockCore

final class MachineConnectionCopyTests: XCTestCase {
    private let label = "acme-mini"

    private func banner(_ tunnel: MachineTunnelState, _ store: ConnectionState) -> String? {
        MachineConnectionCopy.banner(label: label, tunnel: tunnel, store: store)
    }

    func testConnectingWhileTheTunnelIsFirstComingUp() {
        XCTAssertEqual(banner(.connecting, .connecting), "Connecting to acme-mini\u{2026}")
        XCTAssertEqual(banner(.connecting, .notRunning(attempt: 1)), "Connecting to acme-mini\u{2026}")
    }

    func testAuthFailureSuggestsSshAdd() {
        XCTAssertEqual(
            banner(.unreachable(reason: "Permission denied (publickey)."), .reconnecting(attempt: 1)),
            "Can't reach acme-mini. Permission denied (publickey). If your key has a passphrase, run ssh-add, then check that ssh acme-mini works."
        )
    }

    func testHostKeyFailureSuggestsKnownHosts() {
        XCTAssertEqual(
            banner(.unreachable(reason: "Host key verification failed."), .notRunning(attempt: 1)),
            "Can't reach acme-mini. Host key verification failed. Run ssh acme-mini once in Terminal, then add its host key to known_hosts."
        )
        XCTAssertEqual(
            banner(.unreachable(reason: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"), .notRunning(attempt: 1)),
            "Can't reach acme-mini. WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! Run ssh acme-mini once in Terminal, then add its host key to known_hosts."
        )
    }

    func testOtherFailuresCarryOnlyTheReason() {
        XCTAssertEqual(
            banner(.unreachable(reason: "Connection timed out."), .notRunning(attempt: 3)),
            "Can't reach acme-mini. Connection timed out."
        )
        XCTAssertEqual(
            banner(.unreachable(reason: "herdr has no session named work on acme-mini."), .notRunning(attempt: 1)),
            "Can't reach acme-mini. herdr has no session named work on acme-mini."
        )
        XCTAssertEqual(banner(.unreachable(reason: "ssh exited."), .reconnecting(attempt: 2)), "Can't reach acme-mini. ssh exited.")
    }

    func testAReasonWithoutAFullStopGetsOne() {
        XCTAssertEqual(
            banner(.unreachable(reason: "Connection refused"), .notRunning(attempt: 1)),
            "Can't reach acme-mini. Connection refused."
        )
    }

    func testNoServerAndAFormerlyUpForward() {
        XCTAssertEqual(banner(.noServer, .notRunning(attempt: 1)), "herdr isn't running on acme-mini.")
        XCTAssertEqual(banner(.up, .reconnecting(attempt: 2)), "herdr isn't running on acme-mini.")
        XCTAssertEqual(banner(.up, .notRunning(attempt: 1)), "herdr isn't running on acme-mini.")
    }

    func testNoBannerWhenLiveOrStopped() {
        XCTAssertNil(banner(.up, .live))
        XCTAssertNil(banner(.stopped, .notRunning(attempt: 1)))
        XCTAssertNil(banner(.stopped, .live))
    }

    func testUpForwardWhileTheStoreIsFirstConnectingReadsAsConnecting() {
        XCTAssertEqual(banner(.up, .connecting), "Connecting to acme-mini\u{2026}")
    }

    func testVersionWarning() {
        XCTAssertEqual(
            MachineConnectionCopy.versionWarning(label: label, local: "0.9.5", remote: "0.9.6"),
            "acme-mini runs herdr 0.9.6 and this Mac has 0.9.5. Panes may misbehave until they match."
        )
        XCTAssertNil(MachineConnectionCopy.versionWarning(label: label, local: "0.9.5", remote: "0.9.5"))
        XCTAssertNil(MachineConnectionCopy.versionWarning(label: label, local: nil, remote: "0.9.5"))
        XCTAssertNil(MachineConnectionCopy.versionWarning(label: label, local: "0.9.5", remote: nil))
    }

    func testRemoved() {
        XCTAssertEqual(MachineConnectionCopy.removed(label: label), "acme-mini is no longer a saved herdr machine.")
    }
}
