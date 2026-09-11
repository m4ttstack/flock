import XCTest
@testable import PaddockCore

private struct WaitTimedOut: Error {}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw WaitTimedOut() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func pongJSON(protocolVersion: Int) -> String {
    #"{"type":"pong","version":"0.9.0","protocol":\#(protocolVersion)}"#
}

private func snapshotResultJSON(tabLabel: String = "orig") -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"\#(tabLabel)","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[]}}
    """#
}

private let tabRenamedEventLine = #"{"data":{"type":"tab_renamed","tab_id":"w1:t1","label":"renamed-during-boot"}}"#

private let duplicateTabCreatedEventLine = #"{"data":{"type":"tab_created","tab":{"tab_id":"w1:t1","workspace_id":"w1","label":"orig","number":1,"pane_count":1,"agent_status":"unknown"}}}"#

final class HerdrStoreTests: XCTestCase {
    @MainActor
    func testBootstrapBuffersEventsDuringSnapshot() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: snapshotResultJSON())
        let release = fake.holdNext(method: "session.snapshot")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }

        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }
        fake.pushEventLine(tabRenamedEventLine)
        release()

        try await waitUntil { store.connection == .live }
        XCTAssertEqual(store.model?.tabs[WorkspaceID(rawValue: "w1")]?.first?.label, "renamed-during-boot")
    }

    @MainActor
    func testBufferedCreateDedupesAgainstConcurrentSnapshot() async throws {
        // The held snapshot already contains tab w1:t1 (see snapshotResultJSON());
        // a tab_created for that same id, buffered while the snapshot is held,
        // must not produce a second copy once the buffer replays.
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: snapshotResultJSON())
        let release = fake.holdNext(method: "session.snapshot")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }

        try await waitUntil { fake.receivedRequests.contains { $0.method == "events.subscribe" } }
        fake.pushEventLine(duplicateTabCreatedEventLine)
        release()

        try await waitUntil { store.connection == .live }
        let tabs = store.model?.tabs[WorkspaceID(rawValue: "w1")] ?? []
        XCTAssertEqual(tabs.filter { $0.tabID == TabID(rawValue: "w1:t1") }.count, 1)
    }

    @MainActor
    func testReconnectReBootstraps() async throws {
        let fake = FakeHerdrServer(); try fake.start()
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: snapshotResultJSON())

        let store = HerdrStore(socketPath: fake.socketPath, backoffSchedule: { _ in .milliseconds(20) })
        await store.start()
        defer { store.stop() }

        try await waitUntil { store.connection == .live }
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "session.snapshot" }.count, 1)

        fake.stop()
        try fake.restart()

        try await waitUntil(timeout: 3) {
            store.connection == .live
                && fake.receivedRequests.filter({ $0.method == "session.snapshot" }).count >= 2
        }
        fake.stop()
    }

    @MainActor
    func testPeriodicResnapshot() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: snapshotResultJSON())

        let store = HerdrStore(socketPath: fake.socketPath, resnapshotInterval: .milliseconds(50))
        await store.start()
        defer { store.stop() }

        try await waitUntil(timeout: 0.4) {
            fake.receivedRequests.filter { $0.method == "session.snapshot" }.count >= 2
        }
    }

    @MainActor
    func testProtocolFloorSurfacesAsUnsupported() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 19))

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }

        try await waitUntil {
            if case .unsupported = store.connection { return true }
            return false
        }
        guard case .unsupported(let error) = store.connection else { return XCTFail() }
        guard case .protocolTooOld(let found, let required) = error else { return XCTFail() }
        XCTAssertEqual(found, 19)
        XCTAssertEqual(required, 22)
    }
}
