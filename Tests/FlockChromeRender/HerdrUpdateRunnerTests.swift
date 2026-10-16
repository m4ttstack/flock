import FlockCore
import XCTest

/// The real `Process` runner against harmless system binaries, with an empty
/// environment so no login shell is asked for a PATH.
final class HerdrUpdateRunnerTests: XCTestCase {
    func testARunReturnsItsStatusAndOutput() async {
        let runner = ProcessHerdrCommandRunner(deadline: .seconds(10), environment: { [:] })
        let result = await runner.run("/bin/echo", ["installed v0.9.6"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "installed v0.9.6\n")
    }

    func testARunPastItsDeadlineIsStoppedAndReadsAsTimedOut() async {
        let runner = ProcessHerdrCommandRunner(deadline: .milliseconds(200), environment: { [:] })
        let started = Date()
        let result = await runner.run("/bin/sleep", ["30"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the process was not stopped at the deadline")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.output, "timed out")
        XCTAssertEqual(
            HerdrUpdateRun.outcome(status: result.status, output: result.output, binaryChanged: false), .failed("herdr couldn't update: timed out")
        )
    }

    func testAnExecutableThatCannotLaunchIsAFailure() async {
        let runner = ProcessHerdrCommandRunner(deadline: .seconds(10), environment: { [:] })
        let result = await runner.run("/nonexistent/herdr", ["update", "--handoff"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.output.isEmpty)
    }
}
