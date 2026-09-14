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

private func layoutExportResultJSON(tabID: String, focusedPaneID: String, ratio: Double, firstPaneID: String, secondPaneID: String) -> String {
    #"""
    {"layout":{"workspace_id":"w1","tab_id":"\#(tabID)","zoomed":false,"focused_pane_id":"\#(focusedPaneID)","root":{"type":"split","direction":"right","ratio":\#(ratio),"first":{"type":"pane","pane_id":"\#(firstPaneID)"},"second":{"type":"pane","pane_id":"\#(secondPaneID)"}}}}
    """#
}

private func singlePaneLayout(tabID: TabID, paneID: PaneID, splits: [SplitInfo] = [], panes: [PaneRect]? = nil) -> LayoutSnapshot {
    LayoutSnapshot(
        workspaceID: WorkspaceID(rawValue: "w1"),
        tabID: tabID,
        zoomed: false,
        area: CellRect(x: 0, y: 0, width: 100, height: 50),
        focusedPaneID: paneID,
        panes: panes ?? [PaneRect(paneID: paneID, focused: true, rect: CellRect(x: 0, y: 0, width: 100, height: 50))],
        splits: splits
    )
}

final class LayoutExportCoordinatorTests: XCTestCase {
    @MainActor
    func testUnchangedTabSignatureSkipsRefetch() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let tabA = TabID(rawValue: "w1:t1")
        fake.respond(to: "layout.export", withResultJSON: layoutExportResultJSON(tabID: "w1:t1", focusedPaneID: "w1:p1", ratio: 0.5, firstPaneID: "w1:p1", secondPaneID: "w1:p2"))

        let coordinator = LayoutExportCoordinator(client: HerdrClient(socketPath: fake.socketPath))
        let layout = singlePaneLayout(tabID: tabA, paneID: PaneID(rawValue: "w1:p1"))

        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: layout], selectedTabID: tabA)
        await coordinator.waitForIdle()
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 1)
        XCTAssertNotNil(coordinator.exportedLayouts[tabA])

        // Same layout again: no new request.
        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: layout], selectedTabID: tabA)
        await coordinator.waitForIdle()
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 1)
    }

    /// A `pane.swap` leaves the pane set and every split untouched and only
    /// exchanges which pane occupies which rect; the exported tree is stale
    /// the moment that happens, so it must count as a topology change.
    @MainActor
    func testSwappedPanePlacementRefetchesTheTab() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let tabA = TabID(rawValue: "w1:t1")
        fake.respond(to: "layout.export", withResultJSON: layoutExportResultJSON(tabID: "w1:t1", focusedPaneID: "w1:p1", ratio: 0.5, firstPaneID: "w1:p1", secondPaneID: "w1:p2"))

        let coordinator = LayoutExportCoordinator(client: HerdrClient(socketPath: fake.socketPath))
        let rootSplit = SplitInfo(id: "s1", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 100, height: 50))
        let left = CellRect(x: 0, y: 0, width: 50, height: 50)
        let right = CellRect(x: 50, y: 0, width: 50, height: 50)
        let before = singlePaneLayout(
            tabID: tabA, paneID: PaneID(rawValue: "w1:p1"), splits: [rootSplit],
            panes: [
                PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: left),
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: right),
            ]
        )
        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: before], selectedTabID: tabA)
        await coordinator.waitForIdle()
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 1)

        let swapped = singlePaneLayout(
            tabID: tabA, paneID: PaneID(rawValue: "w1:p1"), splits: [rootSplit],
            panes: [
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: left),
                PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: right),
            ]
        )
        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: swapped], selectedTabID: tabA)
        await coordinator.waitForIdle()
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 2)
    }

    @MainActor
    func testRatioOnlyChangeRefetchesOnlyThatTabNotOthers() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let tabA = TabID(rawValue: "w1:t1")
        let tabB = TabID(rawValue: "w1:t2")
        fake.respond(to: "layout.export", withResultJSON: layoutExportResultJSON(tabID: "w1:t1", focusedPaneID: "w1:p1", ratio: 0.5, firstPaneID: "w1:p1", secondPaneID: "w1:p2"))

        let coordinator = LayoutExportCoordinator(client: HerdrClient(socketPath: fake.socketPath))
        let rootSplitA = SplitInfo(id: "s1", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 100, height: 50))
        let layoutA = singlePaneLayout(
            tabID: tabA,
            paneID: PaneID(rawValue: "w1:p1"),
            splits: [rootSplitA],
            panes: [
                PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: CellRect(x: 0, y: 0, width: 50, height: 50)),
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: CellRect(x: 50, y: 0, width: 50, height: 50)),
            ]
        )
        let layoutB = singlePaneLayout(tabID: tabB, paneID: PaneID(rawValue: "w1:p3"))

        coordinator.refresh(tabIDsInOrder: [tabA, tabB], layouts: [tabA: layoutA, tabB: layoutB], selectedTabID: tabA)
        await coordinator.waitForIdle()
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 2)

        // Only tabA's ratio changes.
        let changedRootSplitA = SplitInfo(id: "s1", direction: .right, ratio: 0.7, rect: rootSplitA.rect)
        let changedLayoutA = singlePaneLayout(
            tabID: tabA,
            paneID: PaneID(rawValue: "w1:p1"),
            splits: [changedRootSplitA],
            panes: layoutA.panes
        )
        coordinator.refresh(tabIDsInOrder: [tabA, tabB], layouts: [tabA: changedLayoutA, tabB: layoutB], selectedTabID: tabA)
        await coordinator.waitForIdle()

        // Exactly one more layout.export call: tabA only, never tabB.
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 3)
    }

    @MainActor
    func testUnknownShapeFallsBackToRectDerivation() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let tabA = TabID(rawValue: "w1:t1")
        fake.respond(to: "layout.export", withResultJSON: #"{"layout":{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"focused_pane_id":"w1:p1","root":{"type":"portal"}}}"#)

        let coordinator = LayoutExportCoordinator(client: HerdrClient(socketPath: fake.socketPath))
        let layout = singlePaneLayout(tabID: tabA, paneID: PaneID(rawValue: "w1:p1"))

        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: layout], selectedTabID: tabA)
        await coordinator.waitForIdle()

        XCTAssertTrue(coordinator.fallbackTabs.contains(tabA))
        XCTAssertNil(coordinator.exportedLayouts[tabA])
    }

    @MainActor
    func testTransportFailureFallsBackAndRetriesOnNextRefresh() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let tabA = TabID(rawValue: "w1:t1")
        fake.failNext(method: "layout.export", code: "layout_not_found", message: "layout target not found")

        let coordinator = LayoutExportCoordinator(client: HerdrClient(socketPath: fake.socketPath))
        let layout = singlePaneLayout(tabID: tabA, paneID: PaneID(rawValue: "w1:p1"))

        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: layout], selectedTabID: tabA)
        await coordinator.waitForIdle()
        XCTAssertTrue(coordinator.fallbackTabs.contains(tabA))

        // The next refresh (same unchanged layout) retries rather than
        // treating the earlier failure as a cached, permanent result.
        fake.respond(to: "layout.export", withResultJSON: layoutExportResultJSON(tabID: "w1:t1", focusedPaneID: "w1:p1", ratio: 0.5, firstPaneID: "w1:p1", secondPaneID: "w1:p2"))
        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: layout], selectedTabID: tabA)
        await coordinator.waitForIdle()

        XCTAssertFalse(coordinator.fallbackTabs.contains(tabA))
        XCTAssertNotNil(coordinator.exportedLayouts[tabA])
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 2)
    }

    @MainActor
    func testPrefetchVisitsSelectedTabFirstAndNeverInParallel() async throws {
        let fake = FakeHerdrServer(); try fake.start(); defer { fake.stop() }
        let tabA = TabID(rawValue: "w1:t1")
        let tabB = TabID(rawValue: "w1:t2")
        fake.respond(to: "layout.export", withResultJSON: layoutExportResultJSON(tabID: "w1:t1", focusedPaneID: "w1:p1", ratio: 0.5, firstPaneID: "w1:p1", secondPaneID: "w1:p2"))
        let release = fake.holdNext(method: "layout.export")

        let coordinator = LayoutExportCoordinator(client: HerdrClient(socketPath: fake.socketPath))
        let layoutA = singlePaneLayout(tabID: tabA, paneID: PaneID(rawValue: "w1:p1"))
        let layoutB = singlePaneLayout(tabID: tabB, paneID: PaneID(rawValue: "w1:p3"))

        // tabB is listed first, but tabA is selected: it must be requested first.
        coordinator.refresh(tabIDsInOrder: [tabB, tabA], layouts: [tabA: layoutA, tabB: layoutB], selectedTabID: tabA)

        try await waitUntil { fake.receivedRequests.contains { $0.method == "layout.export" } }
        // While the first (selected-tab) request is held open, the second
        // tab's request must not have been sent yet: chained, not parallel.
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 1)
        XCTAssertEqual(fake.receivedRequests.first?.paramsJSON.contains("w1:t1"), true)

        release()
        await coordinator.waitForIdle()
        XCTAssertEqual(fake.receivedRequests.filter { $0.method == "layout.export" }.count, 2)
    }

    /// Reproduces the completion-after-cancel race directly, with no real
    /// socket involved (so there is no ambiguity about which connection a
    /// server-side hold applies to): the first `layoutExport` call suspends
    /// on a continuation until explicitly released; the second call (issued
    /// once the first is confirmed in flight) resolves immediately. A
    /// superseded fetch resolving late must not be allowed to write once it
    /// finally completes, even though the superseding fetch already landed a
    /// fresher result first.
    @MainActor
    func testSupersededFetchCommitsNothingAndFreshResultWins() async throws {
        let tabA = TabID(rawValue: "w1:t1")
        let paneID = PaneID(rawValue: "w1:p1")
        func exported(ratio: Double) -> ExportedLayoutDescription {
            ExportedLayoutDescription(
                workspaceID: WorkspaceID(rawValue: "w1"), tabID: tabA, zoomed: false, focusedPaneID: paneID,
                root: .split(
                    direction: .right, ratio: ratio,
                    first: .pane(ExportedLayoutPane(paneID: paneID)),
                    second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "w1:p2")))
                )
            )
        }
        let staleResult = exported(ratio: 0.9)
        let freshResult = exported(ratio: 0.7)
        let client = HoldableLayoutExportClient(firstResult: staleResult, secondResult: freshResult)

        let coordinator = LayoutExportCoordinator(client: client)
        let staleLayout = singlePaneLayout(
            tabID: tabA, paneID: paneID,
            splits: [SplitInfo(id: "s1", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 100, height: 50))],
            panes: [
                PaneRect(paneID: paneID, focused: true, rect: CellRect(x: 0, y: 0, width: 50, height: 50)),
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: CellRect(x: 50, y: 0, width: 50, height: 50)),
            ]
        )

        // The first fetch goes out and suspends; `waitUntilFirstCallStarted`
        // returns only once it has genuinely begun (no sleep-based guess).
        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: staleLayout], selectedTabID: tabA)
        await client.waitUntilFirstCallStarted()

        // A layout change (ratio 0.7) supersedes it before it resolves: this
        // cancels the first fetch's task and issues a second call, which
        // resolves immediately (it is not the held one).
        let freshLayout = singlePaneLayout(
            tabID: tabA, paneID: paneID,
            splits: [SplitInfo(id: "s1", direction: .right, ratio: 0.7, rect: CellRect(x: 0, y: 0, width: 100, height: 50))],
            panes: staleLayout.panes
        )
        coordinator.refresh(tabIDsInOrder: [tabA], layouts: [tabA: freshLayout], selectedTabID: tabA)
        await coordinator.waitForIdle()

        XCTAssertEqual(coordinator.exportedLayouts[tabA], freshResult, "the fresh fetch must land before the stale one is even released")

        // Release the superseded fetch; it must commit nothing.
        await client.release()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.exportedLayouts[tabA], freshResult, "a superseded fetch resolving late must not clobber the fresh result already committed")
    }
}

/// The first `layoutExport` call suspends until `release()` is called; every
/// call after that resolves immediately. Lets a test force a fetch to
/// resolve strictly after it has been superseded, without any real socket or
/// server-side hold involved.
private actor HoldableLayoutExportClient: LayoutExportClient {
    private var callCount = 0
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var firstCallStarted = false
    private let firstResult: ExportedLayoutDescription
    private let secondResult: ExportedLayoutDescription

    init(firstResult: ExportedLayoutDescription, secondResult: ExportedLayoutDescription) {
        self.firstResult = firstResult
        self.secondResult = secondResult
    }

    func layoutExport(tabID: TabID) async throws -> ExportedLayoutDescription {
        callCount += 1
        guard callCount == 1 else { return secondResult }
        firstCallStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            heldContinuation = continuation
        }
        return firstResult
    }

    func waitUntilFirstCallStarted() async {
        if firstCallStarted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startedContinuation = continuation
        }
    }

    func release() {
        heldContinuation?.resume()
        heldContinuation = nil
    }
}
