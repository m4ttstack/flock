import FlockCore
import XCTest

/// The real `Process` runner against harmless system binaries, with an empty
/// environment so no login shell is asked for a PATH.
final class HerdrCommandRunnerTests: XCTestCase {
    func testARunReturnsItsStatusAndOutput() async {
        let runner = ProcessHerdrCommandRunner(deadline: .seconds(10), environment: { [:] })
        let result = await runner.run("/bin/echo", ["live handoff complete"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "live handoff complete\n")
    }

    func testARunNamesTheSocketItIsGiven() async {
        let runner = ProcessHerdrCommandRunner(
            deadline: .seconds(10), environment: { ["HERDR_SOCKET_PATH": "/tmp/acme/now.sock", "ACME": "1"] }
        )
        let named = await runner.run("/usr/bin/env", [], socketPath: "/tmp/acme/confirmed.sock")
        XCTAssertEqual(Set(named.output.split(separator: "\n")), ["HERDR_SOCKET_PATH=/tmp/acme/confirmed.sock", "ACME=1"])
        let inherited = await runner.run("/usr/bin/env", [])
        XCTAssertEqual(Set(inherited.output.split(separator: "\n")), ["HERDR_SOCKET_PATH=/tmp/acme/now.sock", "ACME=1"])
    }

    func testARunPastItsDeadlineIsStoppedAndReadsAsTimedOut() async {
        let runner = ProcessHerdrCommandRunner(deadline: .milliseconds(200), environment: { [:] })
        let started = Date()
        let result = await runner.run("/bin/sleep", ["30"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the process was not stopped at the deadline")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.output, "timed out")
    }

    func testAnExecutableThatCannotLaunchIsAFailure() async {
        let runner = ProcessHerdrCommandRunner(deadline: .seconds(10), environment: { [:] })
        let result = await runner.run("/nonexistent/herdr", ["--version"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.output.isEmpty)
    }
}
