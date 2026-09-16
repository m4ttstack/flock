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

    /// herdr seeds its own `last_scroll` from a subscribe-time probe and emits
    /// only on a CHANGE, so a pane scrolled back while paddock was not
    /// watching it would show no indicator until something moved again. The
    /// feed reads the current state itself when it arms.
    @MainActor
    func testArmingTheFeedProbesPaneGetAndRelaysTheCurrentScroll() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        fake.respond(
            to: "pane.get",
            withResultJSON: #"{"pane":{"pane_id":"w1:p2","scroll":{"offset_from_bottom":12,"max_offset_from_bottom":80,"viewport_rows":30}}}"#)
        let received = ScrollLog()
        let subscriber = HerdrPaneScrollSubscriber(socketPath: fake.socketPath) { pane, scroll in
            received.append(pane, scroll)
        }

        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { !received.entries.isEmpty }

        let probe = try XCTUnwrap(fake.receivedRequests.first { $0.method == "pane.get" })
        XCTAssertTrue(probe.paramsJSON.contains(#""pane_id":"w1:p2""#), probe.paramsJSON)
        XCTAssertEqual(received.entries.first?.pane, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(
            received.entries.first?.scroll,
            ScrollInfo(offsetFromBottom: 12, maxOffsetFromBottom: 80, viewportRows: 30))
    }

    /// The probe rides its own connection: herdr answers one request per
    /// connection and treats any further inbound byte on a subscription as a
    /// disconnect, so a probe sent down the feed's own socket would kill it.
    @MainActor
    func testTheProbeDoesNotDisturbTheSubscriptionStream() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        fake.respond(
            to: "pane.get",
            withResultJSON: #"{"pane":{"pane_id":"w1:p2","scroll":{"offset_from_bottom":12,"max_offset_from_bottom":80,"viewport_rows":30}}}"#)
        let received = ScrollLog()
        let subscriber = HerdrPaneScrollSubscriber(socketPath: fake.socketPath) { pane, scroll in
            received.append(pane, scroll)
        }
        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { !received.entries.isEmpty }

        fake.pushEventLine(#"{"event":"pane.scroll_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","scroll":{"offset_from_bottom":3,"max_offset_from_bottom":80,"viewport_rows":30}}}"#)
        try await waitUntil { received.entries.count >= 2 }

        XCTAssertEqual(
            received.entries.last?.scroll,
            ScrollInfo(offsetFromBottom: 3, maxOffsetFromBottom: 80, viewportRows: 30))
    }

    /// A pane herdr reports without scroll state seeds nothing; the indicator
    /// keeps whatever the snapshot already said.
    @MainActor
    func testAProbeWithNoScrollStateSeedsNothing() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        fake.respond(to: "pane.get", withResultJSON: #"{"pane":{"pane_id":"w1:p2"}}"#)
        let received = ScrollLog()
        let subscriber = HerdrPaneScrollSubscriber(socketPath: fake.socketPath) { pane, scroll in
            received.append(pane, scroll)
        }

        subscriber.subscribe(pane: PaneID(rawValue: "w1:p2"))
        try await waitUntil { fake.receivedRequests.contains { $0.method == "pane.get" } }
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(received.entries.isEmpty)
    }

    func testScrollProbeDecoderReadsResultPaneAndRejectsOtherShapes() throws {
        let decoded = try XCTUnwrap(HerdrDecoder.scrollProbe(
            fromLine: Data(#"{"id":"x","result":{"pane":{"pane_id":"w1:p2","scroll":{"offset_from_bottom":7,"max_offset_from_bottom":90,"viewport_rows":40}}}}"#.utf8)))
        XCTAssertEqual(decoded.paneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(decoded.scroll, ScrollInfo(offsetFromBottom: 7, maxOffsetFromBottom: 90, viewportRows: 40))

        XCTAssertNil(HerdrDecoder.scrollProbe(
            fromLine: Data(#"{"id":"x","error":{"code":"not_found","message":"gone"}}"#.utf8)))
        XCTAssertNil(HerdrDecoder.scrollProbe(fromLine: Data("{not json".utf8)))
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

    /// A refusal ends that pane's feed, and the slot it was holding has to go
    /// with it: `subscribe` is a no-op while anything occupies the slot, so a
    /// finished task left behind would make the pane unarmable for the life of
    /// the app. Every attach of a visible pane asks again, which is why the
    /// second arming here is another plain `subscribe`.
    @MainActor
    func testAPaneWhoseSubscriptionWasRefusedCanBeArmedAgain() async throws {
        let fake = FakeHerdrServer()
        try fake.start()
        defer { fake.stop() }
        fake.failNext(method: "events.subscribe", code: "pane_not_found", message: "gone")
        let received = ScrollLog()
        // A retry delay far outside this test's own window, so the second
        // subscribe below can only be the re-arm: a dropped connection's own
        // retry would reuse the slot rather than needing a new one, and would
        // pass this test without the slot ever being released.
        let subscriber = HerdrPaneScrollSubscriber(
            socketPath: fake.socketPath, retryDelay: .seconds(60)
        ) { pane, scroll in
            received.append(pane, scroll)
        }
        let pane = PaneID(rawValue: "w1:p2")

        subscriber.subscribe(pane: pane)
        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }
        // Asked again until it takes, rather than after a fixed pause: the
        // refusal has to be read off the subscription socket before the feed
        // ends, and with the slot still held every one of these is a silent
        // no-op.
        try await waitUntil {
            subscriber.subscribe(pane: pane)
            return fake.receivedRequests.filter { $0.method == "events.subscribe" }.count >= 2
        }

        fake.pushEventLine(#"{"event":"pane.scroll_changed","data":{"pane_id":"w1:p2","workspace_id":"w1","scroll":{"offset_from_bottom":7,"max_offset_from_bottom":90,"viewport_rows":40}}}"#)
        try await waitUntil { !received.entries.isEmpty }

        XCTAssertEqual(
            received.entries.last?.scroll,
            ScrollInfo(offsetFromBottom: 7, maxOffsetFromBottom: 90, viewportRows: 40),
            "the re-armed feed is not relaying frames")
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
