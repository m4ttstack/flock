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

    /// A chat popover's `.task` is cancelled on teardown, well before any
    /// deadline: the deadline here is set far past the assertion bound, so a
    /// prompt return proves cancellation killed the child rather than the
    /// timer.
    func testCancellingTheCallingTaskKillsTheChildAndReturnsPromptly() async throws {
        let runner = ChatRunner(binaryPath: "/bin/sleep", deadline: .seconds(30))
        let started = Date()
        let task = Task {
            try await runner.runRaw(["10"])
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a call cancelled by its caller must throw")
        } catch {
            XCTAssertLessThan(
                Date().timeIntervalSince(started), 5,
                "cancellation must kill the child rather than wait out the deadline"
            )
        }
    }

    /// A cancellation can arrive before the spawn thread has even reached
    /// `Process.run()`: this races that window on every run rather than
    /// asserting it deterministically, since terminating an unlaunched
    /// process is what must never happen, not something observable from
    /// outside.
    func testCancellingBeforeTheChildHasLaunchedNeverHangsOrCrashes() async throws {
        let runner = ChatRunner(binaryPath: "/bin/sleep", deadline: .seconds(30))
        let started = Date()
        let task = Task {
            try await runner.runRaw(["10"])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a call cancelled by its caller must throw")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }
}
