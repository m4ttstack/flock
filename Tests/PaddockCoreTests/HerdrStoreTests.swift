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

/// Three tabs in one workspace, for the moveTab prediction gap-rule tests:
/// leftward and rightward reorders need at least three items to tell
/// "overshoot by one" apart from "land exactly at priorIndex".
private func threeTabSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":null,"workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":0,"agent_status":"unknown"},{"tab_id":"w1:t2","workspace_id":"w1","label":"t2","number":2,"pane_count":0,"agent_status":"unknown"},{"tab_id":"w1:t3","workspace_id":"w1","label":"t3","number":3,"pane_count":0,"agent_status":"unknown"}],"panes":[],"layouts":[]}}
    """#
}

/// One tab with a real 20x10-cell root split (`.right`, ratio 0.5) over two
/// panes, for the `setSplitRatio` prediction tests -- the only op whose
/// prediction needs a real layout to reflow.
private func splitLayoutSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":2,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":20,"height":10},"focused_pane_id":"w1:p1","panes":[{"pane_id":"w1:p1","focused":true,"rect":{"x":0,"y":0,"width":10,"height":10}},{"pane_id":"w1:p2","focused":false,"rect":{"x":10,"y":0,"width":10,"height":10}}],"splits":[{"id":"s1","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":10}}]}]}}
    """#
}

/// One tab, one pane, one `.down` root split at ratio 0.1 over a 2-row
/// area: `childRegions` rounds the first child to 0 rows, so the second
/// child's rect is identical to the root's own -- the degenerate collision
/// `predictedLayout`'s reflow must terminate against rather than re-match
/// the same split forever.
private func degenerateRootSplitSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":10,"height":2},"focused_pane_id":"w1:p1","panes":[{"pane_id":"w1:p1","focused":true,"rect":{"x":0,"y":0,"width":10,"height":2}}],"splits":[{"id":"root","direction":"down","ratio":0.1,"rect":{"x":0,"y":0,"width":10,"height":2}}]}]}}
    """#
}

/// A `.down` root split, ALSO at the same degenerate ratio 0.1/2-row shape
/// as above, but with a REAL nested `.right` split (not a pane) sitting in
/// its degenerate second child -- so the nested split's own rect exactly
/// equals the root's. `splits` lists `root` BEFORE `nested`, so a
/// rect-matching descent (`.first(where:)`) would pick `root` again for
/// ANY path naming `nested`; a path-keyed lookup must not.
private func degenerateRootWithNestedSplitSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":2,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:left","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:right","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":10,"height":2},"focused_pane_id":"w1:left","panes":[{"pane_id":"w1:left","focused":true,"rect":{"x":0,"y":0,"width":5,"height":2}},{"pane_id":"w1:right","focused":false,"rect":{"x":5,"y":0,"width":5,"height":2}}],"splits":[{"id":"root","direction":"down","ratio":0.1,"rect":{"x":0,"y":0,"width":10,"height":2}},{"id":"nested","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":10,"height":2}}]}]}}
    """#
}

/// Split right, split down in the right half, split right in the bottom
/// half: three levels, mixed directions, `splits` listed pre-order
/// root-first (herdr's own emission order) -- the reviewer's own crash
/// reproduction. Containment-based path resolution resolves BOTH `nested`
/// and `deep` to `[true]` (both sit inside `root`'s own second-child region
/// too, not only their true direct parent's), which a `Dictionary
/// (uniqueKeysWithValues:)` built from it then traps on.
/// Two `.down` splits sharing the SAME 2-row rect, each at ratio 0.1 --
/// each one's degenerate second child (`childRegions` rounds the first to 0
/// rows) equals the OTHER split's rect exactly, so a bound that only
/// excludes a split's own id (not a full `visited` set) lets `predictedLayout`
/// resolve `root` to `nested` to `root` to `nested` forever. Reached from
/// every commit's own path resolution, not only the render fallback.
private func mutuallyDegenerateSplitsSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":10,"height":2},"focused_pane_id":"w1:p1","panes":[{"pane_id":"w1:p1","focused":true,"rect":{"x":0,"y":0,"width":10,"height":2}}],"splits":[{"id":"root","direction":"down","ratio":0.1,"rect":{"x":0,"y":0,"width":10,"height":2}},{"id":"nested","direction":"down","ratio":0.1,"rect":{"x":0,"y":0,"width":10,"height":2}}]}]}}
    """#
}

private func threeLevelMixedDirectionNestSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:left","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":4,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:left","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:top","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:deepLeft","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:deepRight","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":20,"height":20},"focused_pane_id":"w1:left","panes":[{"pane_id":"w1:left","focused":true,"rect":{"x":0,"y":0,"width":10,"height":20}},{"pane_id":"w1:top","focused":false,"rect":{"x":10,"y":0,"width":10,"height":10}},{"pane_id":"w1:deepLeft","focused":false,"rect":{"x":10,"y":10,"width":5,"height":10}},{"pane_id":"w1:deepRight","focused":false,"rect":{"x":15,"y":10,"width":5,"height":10}}],"splits":[{"id":"root","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}},{"id":"nested","direction":"down","ratio":0.5,"rect":{"x":10,"y":0,"width":10,"height":20}},{"id":"deep","direction":"right","ratio":0.5,"rect":{"x":10,"y":10,"width":10,"height":10}}]}]}}
    """#
}

private func threeWorkspaceSnapshotResultJSON() -> String {
    #"""
    {"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":null,"workspaces":[{"workspace_id":"w1","label":"w1","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},{"workspace_id":"w2","label":"w2","number":2,"active_tab_id":"w2:t1","agent_status":"unknown"},{"workspace_id":"w3","label":"w3","number":3,"active_tab_id":"w3:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"t1","number":1,"pane_count":0,"agent_status":"unknown"},{"tab_id":"w2:t1","workspace_id":"w2","label":"t1","number":1,"pane_count":0,"agent_status":"unknown"},{"tab_id":"w3:t1","workspace_id":"w3","label":"t1","number":1,"pane_count":0,"agent_status":"unknown"}],"panes":[],"layouts":[]}}
    """#
}

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

    /// herdr's `pane.rename` handler emits no event at all for a
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

    /// A plan whose every op maps to no convergence kind at all (here, a
    /// close) must arm nothing either -- there is no prediction to protect
    /// and no event family to ever wait for.
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

    /// The convergence watch must be armed before the wire round trip
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

    /// A failed plan can still have partially applied real changes on
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

    /// The failure path must not stash a `resolvedConvergence` entry
    /// nothing will ever collect (no task is spawned to await it on
    /// failure), which would leak one dictionary entry per failed `execute`.
    @MainActor
    func testFailedExecuteLeavesNoPendingConvergenceEntry() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "pane.move", withResultJSON: #"{"move_result":{"changed":false,"reason":"zoomed_tab","pane":{"pane_id":"w1:p1"}}}"#)

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        switch await store.execute(plan) {
        case .success: XCTFail("expected a failure")
        case .failure: break
        }

        XCTAssertEqual(store.pendingConvergenceResultCountForTesting, 0)
    }

    /// A generation superseded by a later `execute` (while its own wire call
    /// is still in flight, before anything has started awaiting its
    /// resolution) gets stashed as "not matched" by the supersession itself.
    /// If that superseded generation then goes on to fail, its failure path
    /// must clear that stash too, not just the (already-vacated) pending
    /// watch slot -- otherwise it leaks exactly as before, just reached via
    /// supersession instead of a bare failure.
    @MainActor
    func testDiscardConvergenceClearsAStashLeftBySupersessionBeforeTheOriginalGenerationFails() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: twoTabSnapshotResultJSON())
        fake.respond(to: "tab.rename", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .seconds(30))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let hold = fake.holdNext(method: "pane.move")
        let plan1 = OpPlan(ops: [.movePaneToTab(PaneID(rawValue: "w1:p1"), tab: TabID(rawValue: "w1:t2"), target: nil, split: .right, ratio: nil)], label: "Move")
        let task1 = Task { await store.execute(plan1) }

        // gen1's watch arms synchronously, before its wire call -- confirmed
        // by the request already having reached the (held) fake.
        try await waitUntil { fake.receivedRequests.contains { $0.method == "pane.move" } }

        // gen2 supersedes gen1's still-pending watch while gen1's own call
        // is still blocked: nothing has started awaiting gen1 yet, so the
        // supersession stashes it as "not matched".
        let plan2 = OpPlan(ops: [.renameTab(TabID(rawValue: "w1:t1"), "renamed")], label: "Rename")
        guard case .success = await store.execute(plan2) else { return XCTFail("expected gen2 to succeed") }

        // Now let gen1 proceed -- and fail.
        fake.failNext(method: "pane.move", code: "zoomed_tab", message: "zoomed")
        hold()
        switch await task1.value {
        case .success: XCTFail("expected gen1 to fail")
        case .failure: break
        }

        XCTAssertEqual(store.pendingConvergenceResultCountForTesting, 0)
    }

    // MARK: - moveTab/moveWorkspace prediction gap rule

    @MainActor
    func testMoveTabLeftwardPredictionMatchesTheGapRule() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeTabSnapshotResultJSON())
        fake.respond(to: "tab.move", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        // t3 (index 2) to insertIndex 0: source(2) is not < insert(0), so
        // the actual landing index is 0 -- [t3, t1, t2].
        let plan = OpPlan(ops: [.moveTab(TabID(rawValue: "w1:t3"), insertIndex: 0)], label: "Reorder")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        XCTAssertEqual(
            store.model?.tabs[WorkspaceID(rawValue: "w1")]?.map(\.tabID),
            [TabID(rawValue: "w1:t3"), TabID(rawValue: "w1:t1"), TabID(rawValue: "w1:t2")]
        )
    }

    @MainActor
    func testMoveTabRightwardPredictionMatchesTheGapRule() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeTabSnapshotResultJSON())
        fake.respond(to: "tab.move", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        // t1 (index 0) to insertIndex 2: source(0) < insert(2), so the
        // actual landing index is insert - 1 = 1 -- [t2, t1, t3].
        let plan = OpPlan(ops: [.moveTab(TabID(rawValue: "w1:t1"), insertIndex: 2)], label: "Reorder")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        XCTAssertEqual(
            store.model?.tabs[WorkspaceID(rawValue: "w1")]?.map(\.tabID),
            [TabID(rawValue: "w1:t2"), TabID(rawValue: "w1:t1"), TabID(rawValue: "w1:t3")]
        )
    }

    @MainActor
    func testMoveWorkspaceLeftwardPredictionMatchesTheGapRule() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeWorkspaceSnapshotResultJSON())
        fake.respond(to: "workspace.move", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.moveWorkspace(WorkspaceID(rawValue: "w3"), insertIndex: 0)], label: "Reorder")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        XCTAssertEqual(
            store.model?.workspaces.map(\.workspaceID),
            [WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w2")]
        )
    }

    @MainActor
    func testMoveWorkspaceRightwardPredictionMatchesTheGapRule() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeWorkspaceSnapshotResultJSON())
        fake.respond(to: "workspace.move", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.moveWorkspace(WorkspaceID(rawValue: "w1"), insertIndex: 2)], label: "Reorder")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        XCTAssertEqual(
            store.model?.workspaces.map(\.workspaceID),
            [WorkspaceID(rawValue: "w2"), WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3")]
        )
    }

    /// herdr splices the block in its LISTED order, so a block listed
    /// against rail order ([w3, w1]) predicts [w2, w3, w1], not [w2, w1, w3].
    /// Checked while the wire call is still held, so what is asserted is the
    /// prediction and not a snapshot that followed it.
    @MainActor
    func testMoveWorkspaceBlockPredictionMatchesHerdrsSplice() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeWorkspaceSnapshotResultJSON())
        fake.respond(to: "workspace.move_block", withResultJSON: #"{"type":"workspace_list","workspaces":[]}"#)

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let release = fake.holdNext(method: "workspace.move_block")
        let plan = OpPlan(ops: [.moveWorkspaceBlock([WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w1")], before: nil)], label: "Move workspaces")
        let task = Task { await store.execute(plan) }
        try await waitUntil { fake.receivedRequests.contains { $0.method == "workspace.move_block" } }

        XCTAssertEqual(
            store.model?.workspaces.map(\.workspaceID),
            [WorkspaceID(rawValue: "w2"), WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w1")]
        )
        release()
        guard case .success = await task.value else { return XCTFail("expected the plan to succeed") }
    }

    /// `workspace.move_block` confirms through `workspace.reordered`, never
    /// `workspace.moved`: a watch waiting on the wrong family would time out
    /// and throw the correct prediction away for a resnapshot.
    @MainActor
    func testMoveWorkspaceBlockConvergesOnWorkspaceReorderedWithoutReverting() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeWorkspaceSnapshotResultJSON())
        fake.respond(to: "workspace.move_block", withResultJSON: #"{"type":"workspace_list","workspaces":[]}"#)

        let store = HerdrStore(socketPath: fake.socketPath, overlayConvergenceTimeout: .milliseconds(300))
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.moveWorkspaceBlock([WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3")], before: WorkspaceID(rawValue: "w2"))], label: "Move workspaces")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }
        fake.pushEventLine(#"{"data":{"type":"workspace_reordered","workspace_ids":["w1","w3"],"before_workspace_id":"w2","workspaces":[{"workspace_id":"w1","label":"w1","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},{"workspace_id":"w3","label":"w3","number":2,"active_tab_id":"w3:t1","agent_status":"unknown"},{"workspace_id":"w2","label":"w2","number":3,"active_tab_id":"w2:t1","agent_status":"unknown"}]}}"#)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            store.model?.workspaces.map(\.workspaceID),
            [WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w2")]
        )
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "session.snapshot" }.count, 1, "a timed-out watch resnapshots")
    }

    // MARK: - setSplitRatio prediction (the divider drag's own optimistic overlay)

    /// Before this, `setSplitRatio` predicted nothing at all: the overlay
    /// showed the pre-drag layout until `layout.updated` finally landed, so
    /// a committed drag visibly jumped. The predicted layout must be showing
    /// BEFORE the held `layout.set_split_ratio` response is even allowed to
    /// answer, same shape as the pane-move overlay test above.
    @MainActor
    func testExecuteSetSplitRatioPublishesTheReflowedLayoutBeforeTheWireRoundTripCompletes() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: splitLayoutSnapshotResultJSON())
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let hold = fake.holdNext(method: "layout.set_split_ratio")
        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [], ratio: 0.25)], label: "Resize split")
        let task = Task { await store.execute(plan) }

        try await waitUntil {
            store.model?.layouts[TabID(rawValue: "w1:t1")]?.splits.first(where: { $0.id == "s1" })?.ratio == 0.25
        }
        let layout = try XCTUnwrap(store.model?.layouts[TabID(rawValue: "w1:t1")])
        // 20 cells wide at ratio 0.25 -> first child 5 cells, second 15.
        XCTAssertEqual(layout.panes.first { $0.paneID == PaneID(rawValue: "w1:p1") }?.rect, CellRect(x: 0, y: 0, width: 5, height: 10))
        XCTAssertEqual(layout.panes.first { $0.paneID == PaneID(rawValue: "w1:p2") }?.rect, CellRect(x: 5, y: 0, width: 15, height: 10))

        hold()
        guard case .success = await task.value else { return XCTFail("expected the plan to succeed") }
    }

    /// A path that does not resolve against the tab's own split tree (stale
    /// relative to it, or naming a tab paddock has no layout for at all)
    /// must predict nothing rather than publish a wrong reflow -- the real
    /// `layout.updated` event is still the source of truth once it lands.
    @MainActor
    func testExecuteSetSplitRatioWithAnUnresolvablePathPredictsNothing() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: splitLayoutSnapshotResultJSON())
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true], ratio: 0.25)], label: "Resize split")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        XCTAssertEqual(store.model?.layouts[TabID(rawValue: "w1:t1")]?.splits.first(where: { $0.id == "s1" })?.ratio, 0.5, "an unresolvable path must leave the layout exactly as the snapshot reported it")
    }

    /// A ratio that rounds a child to zero cells makes that child's rect
    /// identical to the split's own -- reachable through nothing more
    /// exotic than a 2-row `.down` region at ratio 0.1, which both herdr's
    /// clamp and the cell-floor fallback permit. Before the path-keyed
    /// rewrite, `predictedLayout`'s reflow re-matched that same split
    /// forever; this asserts the drag resolves at all (a hang or a crash
    /// fails the test outright) and produces the correct reflowed rect.
    @MainActor
    func testExecuteSetSplitRatioTerminatesAndReflowsCorrectlyWhenARatioRoundsAChildToZeroCells() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: degenerateRootSplitSnapshotResultJSON())
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [], ratio: 0.5)], label: "Resize split")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        let layout = try XCTUnwrap(store.model?.layouts[TabID(rawValue: "w1:t1")])
        XCTAssertEqual(layout.splits.first(where: { $0.id == "root" })?.ratio, 0.5)
        // 2 rows at ratio 0.5 -> first child 1 row, second 1 row; the one
        // pane occupies the degenerate second child, so it lands in the
        // second row.
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:p1") })?.rect, CellRect(x: 0, y: 1, width: 10, height: 1))
    }

    /// Two splits mutually degenerate into each other's rect: excluding
    /// only a split's own id from its child match (the round-3 fix) is not
    /// enough to bound this -- `root` resolves to `nested`'s rect, `nested`
    /// resolves to `root`'s rect, forever. A run of this test that
    /// completes at all (rather than stack-overflowing the process) IS the
    /// primary assertion.
    @MainActor
    func testExecuteSetSplitRatioOnMutuallyDegenerateSplitsDoesNotRecurseForever() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: mutuallyDegenerateSplitsSnapshotResultJSON())
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [], ratio: 0.5)], label: "Resize split")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        // Whichever split the resolver treats as "root" (both share the
        // same rect), exactly one of the two ends up at the new ratio.
        let layout = try XCTUnwrap(store.model?.layouts[TabID(rawValue: "w1:t1")])
        let ratios = layout.splits.map(\.ratio)
        XCTAssertTrue(ratios.contains(0.5), "the targeted split resolved and committed")
    }

    /// The same degenerate root, but the collision now sits in front of a
    /// REAL nested split (not a pane) whose own rect happens to equal
    /// root's. `splits` lists `root` before `nested`, so a rect-matching
    /// descent picks whichever comes first in array order -- here, the
    /// WRONG one. A path-keyed lookup must resolve to `nested` regardless
    /// of array order, leaving `root`'s own ratio untouched.
    @MainActor
    func testExecuteSetSplitRatioDescendsToTheCorrectSplitDespiteADegenerateSiblingSharingItsRect() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: degenerateRootWithNestedSplitSnapshotResultJSON())
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true], ratio: 0.25)], label: "Resize split")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        let layout = try XCTUnwrap(store.model?.layouts[TabID(rawValue: "w1:t1")])
        XCTAssertEqual(layout.splits.first(where: { $0.id == "root" })?.ratio, 0.1, "root must be untouched -- the drag targeted nested, not root")
        XCTAssertEqual(layout.splits.first(where: { $0.id == "nested" })?.ratio, 0.25)
        // 10 cols at ratio 0.25 -> round(2.5) = 3 (away from zero), so
        // first child 3 cols, second 7.
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:left") })?.rect, CellRect(x: 0, y: 0, width: 3, height: 2))
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:right") })?.rect, CellRect(x: 3, y: 0, width: 7, height: 2))
    }

    /// The reviewer's own crash reproduction, run end to end: three levels,
    /// mixed directions, `splits` in herdr's own pre-order. Before the
    /// structural rewrite this trapped inside `predictedLayout` (a
    /// `Dictionary(uniqueKeysWithValues:)` built from two splits both
    /// resolved to `[true]`) -- a stack-overflow-free run of this test IS
    /// the primary assertion; the ratio/rect checks confirm it also
    /// resolved to the CORRECT split, not merely survived.
    @MainActor
    func testExecuteSetSplitRatioOnAThreeLevelMixedDirectionNestDoesNotCrashAndTargetsTheDeepestSplit() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        fake.respond(to: "ping", withResultJSON: pongJSON(protocolVersion: 22))
        fake.respond(to: "session.snapshot", withResultJSON: threeLevelMixedDirectionNestSnapshotResultJSON())
        fake.respond(to: "layout.set_split_ratio", withResultJSON: "{}")

        let store = HerdrStore(socketPath: fake.socketPath)
        await store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let plan = OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true, true], ratio: 0.25)], label: "Resize split")
        guard case .success = await store.execute(plan) else { return XCTFail("expected the plan to succeed") }

        let layout = try XCTUnwrap(store.model?.layouts[TabID(rawValue: "w1:t1")])
        XCTAssertEqual(layout.splits.first(where: { $0.id == "root" })?.ratio, 0.5, "root untouched")
        XCTAssertEqual(layout.splits.first(where: { $0.id == "nested" })?.ratio, 0.5, "the middle split untouched")
        XCTAssertEqual(layout.splits.first(where: { $0.id == "deep" })?.ratio, 0.25, "the deepest split is the one that actually resized")
        // 10 cols at ratio 0.25 -> round(2.5) = 3 (away from zero).
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:deepLeft") })?.rect, CellRect(x: 10, y: 10, width: 3, height: 10))
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:deepRight") })?.rect, CellRect(x: 13, y: 10, width: 7, height: 10))
        // Untouched branches keep their own pre-drag rects exactly.
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:left") })?.rect, CellRect(x: 0, y: 0, width: 10, height: 20))
        XCTAssertEqual(layout.panes.first(where: { $0.paneID == PaneID(rawValue: "w1:top") })?.rect, CellRect(x: 10, y: 0, width: 10, height: 10))
    }
}
