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

/// A snapshot with a second, empty tab in the same workspace: the overlay
/// tests move `w1:p1` into `w1:t2` and need a destination that already
/// exists in the model for `HerdrStore`'s prediction to have anything to
/// read (see `predictedEvent` in `HerdrStore.swift`).
private func twoTabSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":1,"agent_status":"unknown"},{"tab_id":"w1:t2","workspace_id":"w1","label":"t2","number":2,"pane_count":0,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[]}}
    """#
}

private let paneMovedToT2EventLine =
    #"{"data":{"type":"pane_moved","pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t2","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"},"previous_pane_id":"w1:p1","previous_workspace_id":"w1","previous_tab_id":"w1:t1"}}"#

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

    // MARK: - execute: optimistic overlay

    @MainActor
    func testExecutePublishesTheOverlayBeforeTheWireRoundTripCompletes() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let hold = fake.holdNext(method: "pane.move")
        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        let task = Task { await store.execute(plan) }

        // The overlay must show the predicted move immediately, before the
        // held `pane.move` request has even been allowed to answer.
        try await waitUntil { store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID == TabID(rawValue: "w1:t2") }

        hold()
        guard case .success = await task.value else { return XCTFail("expected the plan to succeed") }
    }

    @MainActor
    func testOverlayStaysAppliedOnceTheMatchingConvergenceEventArrives() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .milliseconds(100))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }
        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID, TabID(rawValue: "w1:t2"))

        fake.pushEventLine(paneMovedToT2EventLine)
        // Give the timeout window time to have elapsed; a revert here would
        // mean the convergence event failed to cancel it.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID, TabID(rawValue: "w1:t2"), "a matching live event must keep the overlay, not revert it")
    }

    @MainActor
    func testOverlayRevertsOnTimeoutWhenNoConvergenceEventArrives() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .milliseconds(50))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }
        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID, TabID(rawValue: "w1:t2"))

        // No convergence event is ever pushed, so the timeout must fall back
        // to the pre-overlay model (here re-confirmed by a fresh snapshot,
        // which still shows the pane in its original tab).
        try await waitUntil(timeout: 2) {
            store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID == TabID(rawValue: "w1:t1")
        }
    }

    /// F3: herdr's `pane.rename` handler emits no event at all for a
    /// label-only change, so a plan of nothing but renamePane ops must arm
    /// no watch -- there is nothing to ever confirm it with, and a timeout
    /// would otherwise revert a change that in fact landed.
    @MainActor
    func testRenamePaneOnlyPlanArmsNoWatchAndTheOverlayStandsPastTheTimeout() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.rename", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .milliseconds(30))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.renamePane(PaneID(rawValue: "w1:p1"), "scratch")], label: "Rename")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }
        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.label, "scratch")

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.label, "scratch", "no watch was armed, so nothing should ever have reverted this")
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "session.snapshot" }.count, 1, "no timeout-triggered re-snapshot should have fired")
    }

    /// F4(d): a plan whose every op maps to no convergence kind at all
    /// (here, a close) must arm nothing either -- there is no prediction to
    /// protect and no event family to ever wait for.
    @MainActor
    func testCloseOnlyPlanArmsNoWatch() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "tab.close", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .milliseconds(30))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.closeTab(TabID(rawValue: "w1:t2"))], label: "Close tab")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "session.snapshot" }.count, 1, "no timeout-triggered re-snapshot should have fired")
    }

    /// F4(a): the convergence watch must be armed before the wire round trip
    /// starts, since herdr's subscriber polls independently of any one
    /// request -- a matching event can land while the `pane.move` call is
    /// still in flight, and that must still count.
    @MainActor
    func testConvergenceEventDuringTheRoundTripCounts() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .milliseconds(100))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let hold = fake.holdNext(method: "pane.move")
        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        let task = Task { await store.execute(plan) }

        // The request has reached the fake (and is now blocked on the hold)
        // before the confirming event is pushed, so the watch -- armed
        // synchronously before this call was even made -- is the only thing
        // that can have caught it.
        try await waitUntil { fake.receivedRequests.contains { $0.method == "pane.move" } }
        fake.pushEventLine(paneMovedToT2EventLine)
        hold()

        guard case .success = await task.value else { return XCTFail("expected the plan to succeed") }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(store.model?.panes[PaneID(rawValue: "w1:p1")]?.tabID, TabID(rawValue: "w1:t2"), "the event that landed mid-round-trip must still have counted as convergence")
    }

    /// F4(b): a failed plan can still have partially applied real changes on
    /// herdr's side, so the failure path must re-snapshot too, not just
    /// revert to the pre-plan model.
    @MainActor
    func testFailurePathAlsoRequestsAResnapshot() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"changed":false,"reason":"zoomed_tab","pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "session.snapshot" }.count, 1)

        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        switch await store.execute(plan) {
        case .success: XCTFail("expected a failure")
        case .failure: break
        }

        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "session.snapshot" }.count, 2, "the failure path must re-snapshot, not just revert to the pre-plan model")
    }
}
