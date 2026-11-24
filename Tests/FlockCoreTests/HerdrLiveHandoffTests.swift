import FlockCore
import XCTest

final class HerdrLiveHandoffTests: XCTestCase {
    func testTheServerHandoffNamesTheBinaryAndItsVersion() {
        XCTAssertEqual(
            HerdrLiveHandoff.liveHandoffArguments(binaryPath: "/opt/acme/bin/herdr", expectedVersion: "0.9.5-ms.2"),
            ["server", "live-handoff", "--import-exe", "/opt/acme/bin/herdr", "--expected-version", "0.9.5-ms.2"]
        )
    }

    /// `src/cli/server.rs` ends a good `server live-handoff` on this line and
    /// an error on a JSON line with exit 1.
    func testTheServerHandoffCountsOnlyWithItsCompleteLine() {
        XCTAssertTrue(HerdrLiveHandoff.handedOff(status: 0, output: "live handoff complete; server log: /tmp/acme/herdr-server.log\n"))
        XCTAssertFalse(HerdrLiveHandoff.handedOff(status: 1, output: #"{"error":{"code":"handoff_failed","message":"x"}}"#))
        XCTAssertFalse(HerdrLiveHandoff.handedOff(status: 0, output: ""))
    }

    /// A handoff that errored but left the new server running is herdr's own
    /// "complete" outcome.
    func testANewServerFoundAfterAFailedHandoffCounts() {
        let output = "live handoff failed for session default: timed out\nthe updated server is running for session default.\n"
        XCTAssertTrue(HerdrLiveHandoff.handedOff(status: 0, output: output))
    }
}
