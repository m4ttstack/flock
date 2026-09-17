import XCTest
@testable import FlockCore

final class HerdrClientTests: XCTestCase {
    func testRequestResponseRoundTrip() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: #"{"type":"pong","version":"0.9.0","protocol":22}"#)
        let client = HerdrClient(socketPath: fake.socketPath)
        try await client.verifyProtocol()
        XCTAssertEqual(fake.receivedRequests.first?.method, "ping")
    }

    func testProtocolFloorRejected() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: #"{"type":"pong","version":"0.8.0","protocol":19}"#)
        await XCTAssertThrowsErrorAsync(try await HerdrClient(socketPath: fake.socketPath).verifyProtocol()) {
            guard case HerdrClientError.protocolTooOld(19, 22) = $0 else { return XCTFail() }
        }
    }

    func testServerErrorSurfacesTyped() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.failNext(method: "pane.move", code: "zoomed_tab", message: "tab is zoomed")
        let client = HerdrClient(socketPath: fake.socketPath)
        await XCTAssertThrowsErrorAsync(try await client.requestRaw("pane.move", [:])) {
            guard case HerdrClientError.server("zoomed_tab", _) = $0 else { return XCTFail() }
        }
    }

    func testConcurrentRequestsUseSeparateConnections() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.get", withResultJSON: #"{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"idle","revision":1,"cwd":"/tmp"}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)
        try await withThrowingTaskGroup(of: Data.self) { g in
            for _ in 0..<50 { g.addTask { try await client.requestRaw("pane.get", ["pane_id": .string("w1:p1")]) } }
            var n = 0; for try await _ in g { n += 1 }; XCTAssertEqual(n, 50)
        }
        XCTAssertEqual(fake.acceptedConnectionCount, 50)
    }

    func testLargeRequestPayloadWriteCompletes() async throws {
        // Regression: DispatchIO's write handler can fire more than once for
        // one write (partial-progress reports before the final done==true
        // call); a payload large enough to plausibly split pins that a
        // split write still completes exactly once, not a double-resumed
        // continuation crash.
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "pane.get", withResultJSON: #"{"type":"pane_info","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"idle","revision":1,"cwd":"/tmp"}}"#)
        let client = HerdrClient(socketPath: fake.socketPath)
        let padding = String(repeating: "x", count: 1_000_000)
        let data = try await client.requestRaw("pane.get", ["pane_id": .string("w1:p1"), "padding": .string(padding)])
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(fake.receivedRequests.last?.paramsJSON.contains(padding), true)
    }

    /// A herdr that takes the connection and then answers nothing is the one
    /// failure the transport cannot see: the socket is open and healthy, so
    /// without a deadline the caller waits for good. Held rather than
    /// unresponsive-by-luck, so the request is known to have arrived.
    func testARequestNeverAnsweredFailsWithATimeoutRatherThanParking() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let release = fake.holdNext(method: "pane.get")
        defer { release() }
        let client = HerdrClient(socketPath: fake.socketPath, requestTimeout: .milliseconds(150))

        let outcome = OutcomeBox()
        let request = Task {
            do {
                _ = try await client.requestRaw("pane.get", ["pane_id": .string("w1:p1")])
                outcome.record(nil)
            } catch {
                outcome.record(error)
            }
        }
        defer { request.cancel() }

        // Polled rather than awaited: a deadline that does not work parks the
        // request, and awaiting it would hang the whole suite instead of
        // failing this one test.
        let deadline = Date().addingTimeInterval(5)
        while !outcome.finished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(outcome.finished, "the request parked instead of failing")
        guard case HerdrClientError.timedOut("pane.get")? = outcome.error as? HerdrClientError else {
            return XCTFail("expected a timeout, got \(String(describing: outcome.error))")
        }
        XCTAssertTrue(
            fake.receivedRequests.contains { $0.method == "pane.get" },
            "the request never reached the server, so this timed out on something else")
    }

    /// The other half of the same wedge, and the one a deadline alone does not
    /// cover: a herdr that accepts the connection and never READS it. The
    /// socket buffer fills, `DispatchIO.write` stops making progress, and the
    /// deadline's own cancellation is the only thing that can end it -- a
    /// write that ignores cancellation would leave the request's task group
    /// waiting on it after the deadline fired, which is the park the deadline
    /// exists to kill.
    func testARequestToAServerThatNeverReadsFailsInsteadOfParkingOnTheWrite() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.acceptWithoutReading()
        let client = HerdrClient(socketPath: fake.socketPath, requestTimeout: .milliseconds(150))
        // Past any socket buffer either end could hold, so the write really
        // does stop rather than completing into a buffer.
        let payload = String(repeating: "x", count: 4_000_000)

        let outcome = OutcomeBox()
        let request = Task {
            do {
                _ = try await client.requestRaw("pane.get", ["padding": .string(payload)])
                outcome.record(nil)
            } catch {
                outcome.record(error)
            }
        }
        defer { request.cancel() }

        let deadline = Date().addingTimeInterval(5)
        while !outcome.finished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(outcome.finished, "the request parked on the write instead of failing")
        guard case HerdrClientError.timedOut("pane.get")? = outcome.error as? HerdrClientError else {
            return XCTFail("expected a timeout, got \(String(describing: outcome.error))")
        }
    }
}

/// Carries a request's outcome out of the `Task` it ran in.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error??

    var finished: Bool { lock.lock(); defer { lock.unlock() }; return stored != nil }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored ?? nil }

    func record(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        stored = .some(error)
    }
}
