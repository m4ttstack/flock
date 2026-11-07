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

    func testInputReachesTheChildIntact() async throws {
        let payload = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
        let runner = ToolRunner(binaryPath: "/bin/cat", deadline: .seconds(10))
        let result = try await runner.runCapturingStderr([], input: payload)
        XCTAssertEqual(result.stdout, payload)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAChildThatQuitsBeforeReadingItsInputDoesNotKillTheCaller() async throws {
        let payload = Data(count: 4 << 20)
        let runner = ToolRunner(binaryPath: "/bin/sh", deadline: .seconds(10))
        let result = try await runner.runCapturingStderr(["-c", "exit 4"], input: payload)
        XCTAssertEqual(result.exitCode, 4)
    }

    func testChildRunsFromTheHomeDirectory() async throws {
        let result = try await ToolRunner(binaryPath: "/bin/pwd", deadline: .seconds(5)).run(["-P"])
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines), home)
    }

    func testInputReachesTheChildWhateverItsSize() async throws {
        let input = Data(String(repeating: "line of a long problem\n", count: 20_000).utf8)
        let result = try await ToolRunner(binaryPath: "/usr/bin/wc", deadline: .seconds(10)).run(["-c"], input: input)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "\(input.count)")
    }

    func testAChildThatNeverReadsItsInputStillEnds() async throws {
        let input = Data(repeating: 0x61, count: 1_000_000)
        let result = try await ToolRunner(binaryPath: "/bin/sh", deadline: .seconds(10)).run(["-c", "exit 4"], input: input)
        XCTAssertEqual(result.exitCode, 4)
    }

    func testTheChildRunsInTheFolderItIsGiven() async throws {
        let result = try await ToolRunner(binaryPath: "/bin/pwd", deadline: .seconds(5), currentDirectory: "/usr/bin").run(["-P"])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines), "/usr/bin")
    }
}
