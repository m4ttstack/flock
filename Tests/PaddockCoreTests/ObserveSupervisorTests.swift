import XCTest
@testable import PaddockCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct TimeoutError: Error {}

final class ObserveSupervisorTests: XCTestCase {
    private var pidFilePath: String?

    override func tearDown() {
        if let pidFilePath { try? FileManager.default.removeItem(atPath: pidFilePath) }
        pidFilePath = nil
        unsetenv("FAKE_OBSERVE_PID_FILE")
        unsetenv("FAKE_OBSERVE_HANG")
        unsetenv("FAKE_OBSERVE_FIXTURE")
        super.tearDown()
    }

    // MARK: - fixtures / paths

    private static var fakeScriptPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Support/fake-herdr-observe.sh")
            .path
    }

    private static var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/observe.ndjson")
            .path
    }

    private func makeSupervisor(maxAttached: Int = 30) throws -> ObserveSupervisor {
        setenv("FAKE_OBSERVE_FIXTURE", Self.fixturePath, 1)
        return try ObserveSupervisor(herdrBinary: Self.fakeScriptPath, socketPath: "/tmp/paddock-observe-tests.sock", maxAttached: maxAttached)
    }

    // MARK: - helpers

    private func collectFrames(from stream: AsyncStream<TerminalFrame>, timeout: Duration = .seconds(5)) async throws -> [TerminalFrame] {
        try await withThrowingTaskGroup(of: [TerminalFrame].self) { group in
            group.addTask {
                var frames: [TerminalFrame] = []
                for await frame in stream { frames.append(frame) }
                return frames
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func fixtureFrameLines() throws -> [Data] {
        try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
            .split(separator: 0x0A)
            .prefix(3)
            .map { Data($0) }
    }

    // MARK: - tests

    func testFramesArriveDecodedInOrderThenClosedFinishesStream() async throws {
        let supervisor = try makeSupervisor()
        let pane = PaneID(rawValue: "w1:p1")
        let stream = await supervisor.attach(pane, cols: 80, rows: 24)

        let frames = try await collectFrames(from: stream)

        let expected = try fixtureFrameLines().compactMap { line -> TerminalFrame? in
            guard case .frame(let frame) = ObserveWireLine.parse(line) else { return nil }
            return frame
        }
        XCTAssertEqual(frames, expected)
        XCTAssertEqual(frames.map(\.seq), [1, 2, 3])
        let attached = await supervisor.attachedPanes
        XCTAssertTrue(attached.isEmpty, "closed should have detached the pane")
    }

    func testLRUEvictionDetachesLeastRecentlyAttached() async throws {
        setenv("FAKE_OBSERVE_HANG", "1", 1)
        let supervisor = try makeSupervisor(maxAttached: 2)
        let paneA = PaneID(rawValue: "w1:pA")
        let paneB = PaneID(rawValue: "w1:pB")
        let paneC = PaneID(rawValue: "w1:pC")

        // Each stream must stay referenced: AsyncStream tears its session
        // down as soon as its own storage is deallocated (the same
        // mechanism that reclaims a genuinely orphaned consumer), so a
        // discarded `_ = attach(...)` here would self-evict before this
        // test ever gets to exercise LRU eviction.
        let streamA = await supervisor.attach(paneA, cols: 80, rows: 24)
        let streamB = await supervisor.attach(paneB, cols: 80, rows: 24)
        var attached = await supervisor.attachedPanes
        XCTAssertEqual(attached, [paneA, paneB])

        let streamC = await supervisor.attach(paneC, cols: 80, rows: 24)

        attached = await supervisor.attachedPanes
        XCTAssertEqual(attached, [paneB, paneC])
        // Eviction finishes the evicted pane's stream even though its
        // fake process never emits terminal.closed on its own (HANG mode).
        _ = try await collectFrames(from: streamA)
        withExtendedLifetime((streamB, streamC)) {}
    }

    func testDetachKillsTheChildProcess() async throws {
        setenv("FAKE_OBSERVE_HANG", "1", 1)
        let dir = NSTemporaryDirectory()
        let pidFile = dir + "paddock-observe-pid-\(UUID().uuidString)"
        pidFilePath = pidFile
        setenv("FAKE_OBSERVE_PID_FILE", pidFile, 1)

        let supervisor = try makeSupervisor()
        let pane = PaneID(rawValue: "w1:pKill")
        let stream = await supervisor.attach(pane, cols: 80, rows: 24)

        try await waitUntil {
            (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil
        }
        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(pid, 0), 0, "fake child should be alive before detach")

        await supervisor.detach(pane)

        try await waitUntil { kill(pid, 0) != 0 }
        let attached = await supervisor.attachedPanes
        XCTAssertTrue(attached.isEmpty)
        withExtendedLifetime(stream) {}
    }

    func testInitThrowsWhenNoHerdrBinaryResolves() {
        unsetenv("HERDR_BIN")
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/paddock-tests-no-such-dir", 1)
        defer { if let savedPath { setenv("PATH", savedPath, 1) } }

        XCTAssertThrowsError(try ObserveSupervisor(socketPath: "/tmp/paddock-observe-tests.sock")) {
            guard case ObserveSupervisorError.herdrBinaryNotFound = $0 else {
                return XCTFail("expected herdrBinaryNotFound, got \($0)")
            }
        }
    }
}
