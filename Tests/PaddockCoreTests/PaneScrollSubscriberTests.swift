import XCTest
@testable import PaddockCore

private struct WaitTimedOut: Error {}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw WaitTimedOut() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Fed by one `events.subscribe` connection per pane with a single
/// `pane.scroll_changed` subscription naming that pane, never by the blanket
/// subscription.
final class PaneScrollSubscriberTests: XCTestCase {
    @MainActor
    func testSubscribeOpensAPaneScopedSubscriptionAndRelaysScrollFrames() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        let received = ScrollLog()
        let subscriber = HerdrPaneScrollSubscriber(socketPath: fake.socketPath) { pane, scroll in
            received.append(pane, scroll)
        }

        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }
        let request = try XCTUnwrap(fake.receivedRequests.first { $0.method == "events.subscribe" })
        XCTAssertTrue(request.paramsJSON.contains(#""type":"pane.scroll_changed""#), request.paramsJSON)
        XCTAssertTrue(request.paramsJSON.contains(#""pane_id":"w1:p2""#), request.paramsJSON)
        XCTAssertFalse(request.paramsJSON.contains("layout.updated"), "the blanket subscription's types never ride this connection")

        fake.pushEventLine(#"{"event":"pane.scroll_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","scroll":{"offset_from_bottom":7,"max_offset_from_bottom":90,"viewport_rows":40}}}"#)
        try await waitUntil { !received.entries.isEmpty }

        XCTAssertEqual(received.entries.first?.pane, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(received.entries.first?.scroll, ScrollInfo(offsetFromBottom: 7, maxOffsetFromBottom: 90, viewportRows: 40))
    }

    @MainActor
    func testSubscribeIsIdempotentPerPane() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        let subscriber = HerdrPaneScrollSubscriber(socketPath: fake.socketPath) { _, _ in }

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
        let received = ScrollLog()
        let subscriber = HerdrPaneScrollSubscriber(socketPath: fake.socketPath) { pane, scroll in
            received.append(pane, scroll)
        }
        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }

        subscriber.unsubscribe(pane: PaneID(rawValue: "w1:p2"))
        try await Task.sleep(for: .milliseconds(100))
        fake.pushEventLine(#"{"event":"pane.scroll_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","scroll":{"offset_from_bottom":7,"max_offset_from_bottom":90,"viewport_rows":40}}}"#)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(received.entries.isEmpty)
    }
}

private final class ScrollLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(pane: PaneID, scroll: ScrollInfo)] = []

    var entries: [(pane: PaneID, scroll: ScrollInfo)] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ pane: PaneID, _ scroll: ScrollInfo) {
        lock.lock(); defer { lock.unlock() }
        stored.append((pane, scroll))
    }
}
