import XCTest

final class ToolRunnerTests: XCTestCase {
    func testStderrIsCapturedOnlyWhenAsked() async throws {
        let runner = ToolRunner(binaryPath: "/bin/sh", deadline: .seconds(5))
        let script = ["-c", "echo out; echo err >&2; exit 3"]
        let captured = try await runner.runCapturingStderr(script)
        XCTAssertEqual(String(decoding: captured.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: captured.stderr, as: UTF8.self), "err\n")
        XCTAssertEqual(captured.exitCode, 3)
        let plain = try await runner.run(script)
        XCTAssertEqual(String(decoding: plain.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(plain.exitCode, 3)
    }
}
