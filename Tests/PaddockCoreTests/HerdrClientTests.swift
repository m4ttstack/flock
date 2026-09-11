import XCTest
@testable import PaddockCore

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
}
