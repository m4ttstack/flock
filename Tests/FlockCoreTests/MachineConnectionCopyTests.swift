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

    func testUpForwardInItsGraceReadsAsConnectingWhileTheStoreWaitsOutABackoff() {
        func grace(_ store: ConnectionState) -> String? {
            MachineConnectionCopy.banner(label: label, tunnel: .up, store: store, tunnelUpGraceActive: true)
        }
        XCTAssertEqual(grace(.notRunning(attempt: 2)), "Connecting to acme-mini\u{2026}")
        XCTAssertEqual(grace(.reconnecting(attempt: 1)), "Connecting to acme-mini\u{2026}")
        XCTAssertNil(grace(.live))
    }

    func testUpForwardAfterItsGraceReadsAsNotRunning() {
        let after = MachineConnectionCopy.banner(
            label: label, tunnel: .up, store: .notRunning(attempt: 2), tunnelUpGraceActive: false
        )
        XCTAssertEqual(after, "herdr isn't running on acme-mini.")
    }

    func testGraceChangesNothingWhileTheTunnelIsNotUp() {
        XCTAssertEqual(
            MachineConnectionCopy.banner(label: label, tunnel: .noServer, store: .notRunning(attempt: 1), tunnelUpGraceActive: true),
            "herdr isn't running on acme-mini."
        )
        XCTAssertEqual(
            MachineConnectionCopy.banner(
                label: label, tunnel: .unreachable(reason: "Connection timed out."), store: .notRunning(attempt: 1),
                tunnelUpGraceActive: true
            ),
            "Can't reach acme-mini. Connection timed out."
        )
    }

    func testNoticeCarriesTheGraceThrough() {
        func notice(grace: Bool) -> String? {
            MachineConnectionCopy.notice(
                label: label, tunnel: .up, store: .notRunning(attempt: 1), local: nil, remote: nil, removed: false,
                tunnelUpGraceActive: grace
            )
        }
        XCTAssertEqual(notice(grace: true), "Connecting to acme-mini\u{2026}")
        XCTAssertEqual(notice(grace: false), "herdr isn't running on acme-mini.")
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

    func testNoticePrefersRemovedThenBannerThenAVersionWarningWhileLive() {
        func notice(_ tunnel: MachineTunnelState, _ store: ConnectionState, removed: Bool = false, remote: String? = "0.9.6") -> String? {
            MachineConnectionCopy.notice(
                label: label, tunnel: tunnel, store: store, local: "0.9.5", remote: remote, removed: removed
            )
        }
        XCTAssertEqual(notice(.up, .live, removed: true), "acme-mini is no longer a saved herdr machine.")
        XCTAssertEqual(notice(.noServer, .notRunning(attempt: 1)), "herdr isn't running on acme-mini.")
        XCTAssertEqual(
            notice(.up, .live),
            "acme-mini runs herdr 0.9.6 and this Mac has 0.9.5. Panes may misbehave until they match."
        )
        XCTAssertNil(notice(.up, .live, remote: "0.9.5"))
        XCTAssertNil(notice(.up, .unsupported(.timedOut(method: "x"))), "the version warning only shows while live")
    }

    func testShortKeepsTheFirstSentenceOnly() {
        XCTAssertEqual(
            MachineConnectionCopy.short(
                "Can't reach acme-mini. Permission denied (publickey). If your key has a passphrase, run ssh-add, then check that ssh acme-mini works."
            ),
            "Can't reach acme-mini."
        )
        XCTAssertEqual(
            MachineConnectionCopy.short("acme-mini runs herdr 0.9.6 and this Mac has 0.9.5. Panes may misbehave until they match."),
            "acme-mini runs herdr 0.9.6 and this Mac has 0.9.5."
        )
        XCTAssertEqual(MachineConnectionCopy.short("herdr isn't running on acme-mini."), "herdr isn't running on acme-mini.")
        XCTAssertEqual(MachineConnectionCopy.short("Connecting to acme-mini\u{2026}"), "Connecting to acme-mini\u{2026}")
        XCTAssertEqual(MachineConnectionCopy.short(""), "")
    }

    func testRemoved() {
        XCTAssertEqual(MachineConnectionCopy.removed(label: label), "acme-mini is no longer a saved herdr machine.")
    }

    func testDetailIsWhatFollowsTheFirstSentence() {
        let full = "Can't reach acme-mini. Host key verification failed. Run ssh acme-mini once in Terminal, then add its host key to known_hosts."
        XCTAssertEqual(MachineConnectionCopy.short(full), "Can't reach acme-mini.")
        XCTAssertEqual(
            MachineConnectionCopy.detail(full),
            "Host key verification failed. Run ssh acme-mini once in Terminal, then add its host key to known_hosts."
        )
        XCTAssertEqual(MachineConnectionCopy.detail("herdr isn't running on acme-mini."), "")
    }
}
