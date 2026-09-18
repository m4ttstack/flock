import Foundation
import XCTest

/// Driven against `/bin/echo` and `/bin/sleep`, never `herdr-chat`: a real
/// verb would reach a live daemon and real agent panes.
final class ChatRunnerTests: XCTestCase {
    func testItReadsStdoutAndTheExitCode() async throws {
        let runner = ChatRunner(binaryPath: "/bin/echo", deadline: .seconds(5))
        let out = try await runner.runRaw(["hello"])
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .newlines), "hello")
        XCTAssertEqual(out.exitCode, 0)
    }

    /// A hung rt daemon must fail the call rather than leave a spinner up
    /// forever, and the child must not outlive the deadline either.
    func testACallThatOverrunsItsDeadlineFailsAndKillsTheChild() async {
        let runner = ChatRunner(binaryPath: "/bin/sleep", deadline: .milliseconds(200))
        let started = Date()
        do {
            _ = try await runner.runRaw(["10"])
            XCTFail("a call past its deadline must throw")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline did not fire")
        }
    }
}
