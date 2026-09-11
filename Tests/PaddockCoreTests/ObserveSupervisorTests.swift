import XCTest
@testable import PaddockCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct TimeoutError: Error {}

private func waitUntilAsync(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Lets the choreography task in `testReattachDropsStaleOldDimensionFrames`
/// poll how many frames of each width have arrived so far, instead of
/// guessing a fixed delay long enough for the (cold-start-sensitive) old
/// process to actually be producing output.
private actor FrameCollector {
    private(set) var frames: [TerminalFrame] = []

    func append(_ frame: TerminalFrame) {
        frames.append(frame)
    }

    func count(width: Int) -> Int {
        frames.filter { $0.width == width }.count
    }
}

final class ObserveSupervisorTests: XCTestCase {
    private var pidFilePath: String?

    override func tearDown() {
        if let pidFilePath { try? FileManager.default.removeItem(atPath: pidFilePath) }
        pidFilePath = nil
        unsetenv("FAKE_OBSERVE_PID_FILE")
        unsetenv("FAKE_OBSERVE_HANG")
        unsetenv("FAKE_OBSERVE_FIXTURE")
        unsetenv("FAKE_OBSERVE_CONTINUOUS")
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

        let streamA = await supervisor.attach(paneA, cols: 80, rows: 24)
        _ = await supervisor.attach(paneB, cols: 80, rows: 24)
        var attached = await supervisor.attachedPanes
        XCTAssertEqual(attached, [paneA, paneB])

        _ = await supervisor.attach(paneC, cols: 80, rows: 24)

        attached = await supervisor.attachedPanes
        XCTAssertEqual(attached, [paneB, paneC])
        // Eviction finishes the evicted pane's stream even though its
        // fake process never emits terminal.closed on its own (HANG mode).
        _ = try await collectFrames(from: streamA)

        // HANG-mode children never exit on their own; detach explicitly
        // rather than leaving cleanup to actor deinit timing.
        await supervisor.detach(paneB)
        await supervisor.detach(paneC)
    }

    func testDetachKillsTheChildProcess() async throws {
        setenv("FAKE_OBSERVE_HANG", "1", 1)
        let dir = NSTemporaryDirectory()
        let pidFile = dir + "paddock-observe-pid-\(UUID().uuidString)"
        pidFilePath = pidFile
        setenv("FAKE_OBSERVE_PID_FILE", pidFile, 1)

        let supervisor = try makeSupervisor()
        let pane = PaneID(rawValue: "w1:pKill")
        _ = await supervisor.attach(pane, cols: 80, rows: 24)

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
    }

    func testDroppingStreamWithoutIteratingLeavesSessionAttached() async throws {
        setenv("FAKE_OBSERVE_HANG", "1", 1)
        let supervisor = try makeSupervisor()
        let pane = PaneID(rawValue: "w1:pOrphan")

        // Deliberately discarded, never iterated: onTermination cannot tell
        // this apart from a mid-iteration cancellation, so it must NOT be a
        // teardown trigger (relaxed contract per fix round 1).
        _ = await supervisor.attach(pane, cols: 80, rows: 24)

        // Give AsyncStream's storage every chance to deinit and fire
        // onTermination, if it were (incorrectly) wired to react to it.
        try await Task.sleep(for: .milliseconds(200))
        var attached = await supervisor.attachedPanes
        XCTAssertEqual(attached, [pane], "a dropped-but-never-iterated stream must not kill the session")

        await supervisor.detach(pane)
        attached = await supervisor.attachedPanes
        XCTAssertTrue(attached.isEmpty, "explicit detach must still kill the session")
    }

    func testReattachDropsStaleOldDimensionFrames() async throws {
        let supervisor = try makeSupervisor()
        // A throwaway attach first: this process's very first spawned child
        // pays a one-time cold-start cost getting its Pipe's readability
        // source live, which otherwise eats into the timing below and makes
        // the real assertions flaky in isolation.
        let warmupPane = PaneID(rawValue: "w1:pWarmup")
        _ = try await collectFrames(from: supervisor.attach(warmupPane, cols: 80, rows: 24))

        setenv("FAKE_OBSERVE_CONTINUOUS", "1", 1)
        let pane = PaneID(rawValue: "w1:pResize")
        let stream = await supervisor.attach(pane, cols: 80, rows: 24)
        let collector = FrameCollector()

        let frames = try await withThrowingTaskGroup(of: [TerminalFrame].self) { group in
            group.addTask {
                for await frame in stream { await collector.append(frame) }
                return await collector.frames
            }
            group.addTask {
                // Wait for real evidence the old (80x24) process is
                // producing output (never a fixed guessed delay), some of
                // it plausibly still in flight on its pipe-queue thread,
                // then reattach at new dims mid-stream and wait for real
                // evidence of the new process's own output before stopping
                // everything.
                try await waitUntilAsync { await collector.count(width: 80) >= 3 }
                await supervisor.reattach(pane, cols: 100, rows: 30)
                try await waitUntilAsync { await collector.count(width: 100) >= 3 }
                await supervisor.detach(pane)
                // Fallback only: reached if detach() somehow failed to
                // finish the stream promptly.
                try await Task.sleep(for: .seconds(5))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        guard let firstOld = frames.firstIndex(where: { $0.width == 80 }) else {
            return XCTFail("expected at least one old-dims frame before reattach")
        }
        guard let firstNew = frames.firstIndex(where: { $0.width == 100 }) else {
            return XCTFail("expected at least one new-dims frame after reattach")
        }
        XCTAssertLessThan(firstOld, firstNew)
        let afterNew = frames[frames.index(after: firstNew)...]
        XCTAssertTrue(
            afterNew.allSatisfy { $0.width == 100 },
            "stale old-dims frame(s) arrived after reattach: widths=\(afterNew.map(\.width))"
        )
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
