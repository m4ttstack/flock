import XCTest
@testable import PaddockCore

private struct AgentStatusWaitTimedOut: Error {}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw AgentStatusWaitTimedOut() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Fed by one `events.subscribe` connection per pane with a single
/// `pane.agent_status_changed` subscription naming that pane. herdr has no
/// session-wide form of this event, so the blanket subscription cannot carry
/// it and a pane nobody is watching would otherwise never report.
final class PaneAgentStatusSubscriberTests: XCTestCase {
    @MainActor
    func testSubscribeOpensAPaneScopedSubscriptionAndRelaysStatusFrames() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        let received = AgentStatusLog()
        let subscriber = HerdrPaneAgentStatusSubscriber(socketPath: fake.socketPath) { pane, status in
            received.append(pane, status)
        }

        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }
        let request = try XCTUnwrap(fake.receivedRequests.first { $0.method == "events.subscribe" })
        XCTAssertTrue(request.paramsJSON.contains(#""type":"pane.agent_status_changed""#), request.paramsJSON)
        XCTAssertTrue(request.paramsJSON.contains(#""pane_id":"w1:p2""#), request.paramsJSON)
        XCTAssertFalse(request.paramsJSON.contains("layout.updated"), "the blanket subscription's types never ride this connection")

        fake.pushEventLine(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","agent_status":"blocked"}}"#)
        try await waitUntil { !received.entries.isEmpty }

        XCTAssertEqual(received.entries.first?.pane, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(received.entries.first?.status, .blocked)
    }

    /// herdr seeds its own comparison value from a probe taken when the
    /// subscription is created and emits only on a CHANGE from it, so a
    /// status that moved between the bootstrap snapshot and this subscribe
    /// would be reported by nobody. The feed reads it itself.
    @MainActor
    func testArmingTheFeedProbesPaneGetAndRelaysTheCurrentStatus() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        fake.respond(to: "pane.get", withResultJSON: #"{"pane":{"pane_id":"w1:p2","agent_status":"working"}}"#)
        let received = AgentStatusLog()
        let subscriber = HerdrPaneAgentStatusSubscriber(socketPath: fake.socketPath) { pane, status in
            received.append(pane, status)
        }

        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { !received.entries.isEmpty }

        let probe = try XCTUnwrap(fake.receivedRequests.first { $0.method == "pane.get" })
        XCTAssertTrue(probe.paramsJSON.contains(#""pane_id":"w1:p2""#), probe.paramsJSON)
        XCTAssertEqual(received.entries.first?.status, .working)
    }

    @MainActor
    func testSubscribeIsIdempotentPerPane() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        let subscriber = HerdrPaneAgentStatusSubscriber(socketPath: fake.socketPath) { _, _ in }

        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "events.subscribe" }.count, 1)
    }

    @MainActor
    func testUnsubscribeStopsRelayingFrames() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        let received = AgentStatusLog()
        let subscriber = HerdrPaneAgentStatusSubscriber(socketPath: fake.socketPath) { pane, status in
            received.append(pane, status)
        }
        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }

        subscriber.unsubscribe(pane: PaneID(rawValue: "w1:p2"))
        try await Task.sleep(for: .milliseconds(100))
        fake.pushEventLine(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","agent_status":"blocked"}}"#)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(received.entries.isEmpty)
    }

    /// Both pane-scoped feeds decode off the same envelope shape, so each has
    /// to reject the other's frames rather than half-decoding them.
    func testStatusDecoderReadsItsOwnFramesAndNobodyElses() throws {
        let decoded = try XCTUnwrap(HerdrDecoder.agentStatusChanged(
            fromLine: Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","agent_status":"done"}}"#.utf8)))
        XCTAssertEqual(decoded.paneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(decoded.status, .done)

        XCTAssertNil(HerdrDecoder.agentStatusChanged(
            fromLine: Data(#"{"event":"pane.scroll_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","scroll":{"offset_from_bottom":7,"max_offset_from_bottom":90,"viewport_rows":40}}}"#.utf8)))
        XCTAssertNil(HerdrDecoder.agentStatusChanged(fromLine: Data(#"{"id":"x","result":{"type":"subscribed"}}"#.utf8)))
        XCTAssertNil(HerdrDecoder.agentStatusChanged(fromLine: Data("{not json".utf8)))
    }

    func testStatusProbeDecoderReadsResultPaneAndRejectsOtherShapes() throws {
        let decoded = try XCTUnwrap(HerdrDecoder.agentStatusProbe(
            fromLine: Data(#"{"id":"x","result":{"pane":{"pane_id":"w1:p2","agent_status":"blocked"}}}"#.utf8)))
        XCTAssertEqual(decoded.paneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(decoded.status, .blocked)

        XCTAssertNil(HerdrDecoder.agentStatusProbe(
            fromLine: Data(#"{"id":"x","error":{"code":"not_found","message":"gone"}}"#.utf8)))
        XCTAssertNil(HerdrDecoder.agentStatusProbe(fromLine: Data("{not json".utf8)))
    }
}

private final class AgentStatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(pane: PaneID, status: AgentStatus)] = []

    var entries: [(pane: PaneID, status: AgentStatus)] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ pane: PaneID, _ status: AgentStatus) {
        lock.lock(); defer { lock.unlock() }
        stored.append((pane, status))
    }
}
