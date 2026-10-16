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

    func testAZeroExitIsAnUpdate() {
        XCTAssertEqual(HerdrUpdateRun.outcome(status: 0, output: "installed v0.9.6\n"), .updated)
    }

    func testAFailureQuotesTheLastNonEmptyLine() {
        let output = "checking stable channel for updates...\ndownloading v0.9.6...\nupdate failed: download failed\n\n  \n"
        XCTAssertEqual(
            HerdrUpdateRun.outcome(status: 1, output: output), .failed("herdr couldn't update: download failed")
        )
        XCTAssertEqual(
            HerdrUpdateRun.outcome(status: 1, output: "self-update is disabled for mise installs; run `mise upgrade herdr`"),
            .failed("herdr couldn't update: self-update is disabled for mise installs; run `mise upgrade herdr`")
        )
    }

    func testAFailureWithNoOutputNamesTheExitStatus() {
        XCTAssertEqual(
            HerdrUpdateRun.outcome(status: 2, output: "\n \n"), .failed("herdr couldn't update: it exited with status 2")
        )
    }

    func testTheRestartPromptAfterAnUpdateAsksToReconnect() {
        XCTAssertEqual(
            HerdrMousePatchCopy.restartHeadline(for: .herdrUpdated(patchReinstalled: false)), "herdr is updated"
        )
        XCTAssertEqual(
            HerdrMousePatchCopy.restartHeadline(for: .herdrUpdated(patchReinstalled: true)),
            "herdr is updated and mouse support reinstalled"
        )
        for reinstalled in [false, true] {
            XCTAssertEqual(
                HerdrMousePatchCopy.restartDetail(for: .herdrUpdated(patchReinstalled: reinstalled)),
                "Restart Flock so your panes reconnect."
            )
        }
        XCTAssertEqual(HerdrMousePatchCopy.restartDetail(for: .installed), "Restart Flock so your panes pick it up.")
    }
}
