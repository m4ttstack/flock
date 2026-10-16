import FlockCore
import XCTest

final class HerdrUpdateRunTests: XCTestCase {
    private let plain = HerdrUpdateNotice.available(
        latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: true
    )
    private let warning = HerdrUpdateNotice.breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff")

    func testThePlainConfirmationNamesTheVersionAndTheRestart() {
        let confirmation = HerdrUpdateRun.confirmation(for: plain)
        XCTAssertEqual(confirmation.title, "Update herdr to 0.9.6?")
        XCTAssertEqual(
            confirmation.message,
            "flock runs herdr update --handoff. Your panes keep running; Flock restarts afterwards to reconnect them."
        )
        XCTAssertEqual(confirmation.confirmButtonTitle, "Update")
    }

    func testTheWarningConfirmationAddsThatMouseSupportTurnsOff() {
        let confirmation = HerdrUpdateRun.confirmation(for: warning)
        XCTAssertEqual(confirmation.title, "Update herdr to 0.9.6?")
        XCTAssertEqual(
            confirmation.message,
            "flock runs herdr update --handoff. Your panes keep running; Flock restarts afterwards to reconnect them."
                + " Mouse support turns off until a flock update adds a patch for 0.9.6."
        )
    }

    func testTheRunIsHerdrsOwnHandoffUpdate() {
        XCTAssertEqual(HerdrUpdateRun.arguments, ["update", "--handoff"])
    }

    /// herdr v0.9.5's output for a handoff, from the lines `src/update.rs` prints.
    private let handoffOutput = """
        checking stable channel for updates...
        running herdr targets:
          default: server v0.9.5 (handoff supported)
          update: 0.9.6

        downloading 0.9.6...
        downloaded 0.9.6
        installed 0.9.6
        asking session default to hand off live panes to the updated server...
        live handoff complete for session default; pane processes should still be running.

        """

    func testAHandoffLineIsAnUpdate() {
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: handoffOutput, binaryChanged: false), .updated)
    }

    /// A new binary is not a handoff: herdr installs it and still leaves the
    /// old server running when it cannot ask to stop it.
    func testANewBinaryWithoutAHandoffLineIsNotAnUpdate() {
        let output = """
            downloaded 0.9.6
            installed 0.9.6
            live handoff failed for session default: timed out
            not stopping the old server from a non-interactive update; run `herdr server stop` when you are ready.

            """
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: output, binaryChanged: true), .installedWithoutHandoff("0.9.6"))
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: "", binaryChanged: true), .installedWithoutHandoff(nil))
    }

    /// A handoff that errored but left the updated server running is herdr's
    /// own "complete" outcome.
    func testAnUpdatedServerFoundAfterAFailedHandoffIsAnUpdate() {
        let output = "live handoff failed for session default: timed out\nthe updated server is running for session default.\n"
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: output, binaryChanged: false), .updated)
    }

    func testAlreadyUpToDateCarriesTheVersionOnDisk() {
        let output = "checking stable channel for updates...\nalready up to date (0.9.6)\n"
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: output, binaryChanged: false), .alreadyUpToDate("0.9.6"))
    }

    func testAnyOtherCleanExitIsNotAHandoff() {
        let output = "installed 0.9.6\nnot stopping the old server from a non-interactive update; run `herdr server stop` when you are ready.\n"
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: output, binaryChanged: false), .notHandedOff)
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: "", binaryChanged: false), .notHandedOff)
        XCTAssertEqual(
            HerdrUpdateRun.notHandedOffMessage, "herdr didn't hand off to the new version. Nothing else was changed."
        )
    }

    func testTheServerHandoffNamesTheBinaryAndItsVersion() {
        XCTAssertEqual(
            HerdrUpdateRun.liveHandoffArguments(binaryPath: "/opt/acme/bin/herdr", expectedVersion: "0.9.6"),
            ["server", "live-handoff", "--import-exe", "/opt/acme/bin/herdr", "--expected-version", "0.9.6"]
        )
    }

    /// `src/cli/server.rs` ends a good `server live-handoff` on this line and
    /// an error on a JSON line with exit 1.
    func testTheServerHandoffCountsOnlyWithItsCompleteLine() {
        XCTAssertTrue(HerdrUpdateRun.handedOff(status: 0, output: "live handoff complete; server log: /tmp/acme/herdr-server.log\n"))
        XCTAssertFalse(HerdrUpdateRun.handedOff(status: 1, output: #"{"error":{"code":"handoff_failed","message":"x"}}"#))
        XCTAssertFalse(HerdrUpdateRun.handedOff(status: 0, output: ""))
    }

    func testAFailureQuotesTheLastNonEmptyLine() {
        let output = "checking stable channel for updates...\ndownloading v0.9.6...\nupdate failed: download failed\n\n  \n"
        XCTAssertEqual(
            HerdrUpdateRun.outcome(status: 1, output: output, binaryChanged: false),
            .failed("herdr couldn't update: download failed")
        )
        XCTAssertEqual(
            HerdrUpdateRun.outcome(
                status: 1, output: "self-update is disabled for mise installs; run `mise upgrade herdr`", binaryChanged: false
            ),
            .failed("herdr couldn't update: self-update is disabled for mise installs; run `mise upgrade herdr`")
        )
    }

    func testAFailureWithNoOutputNamesTheExitStatus() {
        XCTAssertEqual(
            HerdrUpdateRun.outcome(status: 2, output: "\n \n", binaryChanged: false),
            .failed("herdr couldn't update: it exited with status 2")
        )
    }

    func testTheRestartPromptAfterAnUpdateAsksToReconnect() {
        XCTAssertEqual(HerdrMousePatchCopy.restartHeadline(for: .herdrUpdated(.untouched)), "herdr is updated")
        XCTAssertEqual(HerdrMousePatchCopy.restartHeadline(for: .herdrUpdated(.reinstalling)), "herdr is updated")
        XCTAssertEqual(HerdrMousePatchCopy.restartHeadline(for: .herdrUpdated(.reinstallFailed)), "herdr is updated")
        XCTAssertEqual(
            HerdrMousePatchCopy.restartHeadline(for: .herdrUpdated(.reinstalled)),
            "herdr is updated and mouse support reinstalled"
        )
        for patch in [HerdrMousePatchCopy.PatchAfterUpdate.untouched, .reinstalled] {
            XCTAssertEqual(
                HerdrMousePatchCopy.restartDetail(for: .herdrUpdated(patch)), "Restart Flock so your panes reconnect."
            )
        }
        XCTAssertEqual(
            HerdrMousePatchCopy.restartDetail(for: .herdrUpdated(.reinstallFailed)),
            "Mouse support couldn't be reinstalled; see Settings."
        )
        XCTAssertEqual(
            HerdrMousePatchCopy.restartDetail(for: .herdrUpdated(.reinstalling)),
            "Reinstalling mouse support, then restart Flock so your panes reconnect."
        )
        XCTAssertEqual(HerdrMousePatchCopy.restartDetail(for: .installed), "Restart Flock so your panes pick it up.")
    }

    func testRestartWaitsOnlyForAReinstallInProgress() {
        XCTAssertFalse(HerdrMousePatchCopy.offersRestart(for: .herdrUpdated(.reinstalling)))
        for reason in [HerdrMousePatchCopy.RestartReason.installed, .restored, .herdrUpdated(.untouched),
                       .herdrUpdated(.reinstalled), .herdrUpdated(.reinstallFailed)] {
            XCTAssertTrue(HerdrMousePatchCopy.offersRestart(for: reason))
        }
    }
}
