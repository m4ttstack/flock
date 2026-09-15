import XCTest
@testable import PaddockCore

private actor RecordingCommandClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private var holdEnabled = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Every subsequent `requestRaw` call suspends until `releaseNext()`
    /// resumes it, one call at a time (FIFO) -- lets a test observe state
    /// mid-flight, before a request completes.
    func hold() { holdEnabled = true }

    func releaseNext() {
        guard !pendingContinuations.isEmpty else { return }
        pendingContinuations.removeFirst().resume()
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        if holdEnabled {
            await withCheckedContinuation { pendingContinuations.append($0) }
        }
        return Data("{}".utf8)
    }
}

private struct RequestFailure: Error {}

private actor FailingCommandClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        throw RequestFailure()
    }
}

private actor FakeLayoutExportClient: LayoutExportClient {
    private(set) var calls: [TabID] = []
    private let result: ExportedLayoutDescription

    init(result: ExportedLayoutDescription) {
        self.result = result
    }

    func layoutExport(tabID: TabID) async throws -> ExportedLayoutDescription {
        calls.append(tabID)
        return result
    }
}

/// Records requests like `RecordingCommandClient` but answers `pane.split`
/// with a canned new-pane id, matching herdr's real `result.pane.pane_id`
/// response shape (pinned by `spikes/lib/seed-layout.sh`'s own read of it).
private actor StubSplitCommandClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private let newPaneID: String

    init(newPaneID: String = "w1:p2") {
        self.newPaneID = newPaneID
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        guard method == "pane.split" else { return Data("{}".utf8) }
        return Data(#"{"result":{"pane":{"pane_id":"\#(newPaneID)"}}}"#.utf8)
    }
}

/// A `PlanExecuting` double for `perform`/`closePane` routing tests: records
/// every plan handed to it and, absent a queued `nextResult`, trivially
/// succeeds with an empty inverse (adequate for tests that only care where
/// the OUTCOME was routed, not what a real inverse would contain).
@MainActor
private final class FakePlanExecutor: PlanExecuting {
    private(set) var executedPlans: [OpPlan] = []
    var nextResult: Result<ExecutedPlan, OpFailure>?

    func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        executedPlans.append(plan)
        if let nextResult { return nextResult }
        return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: [], label: "Undo \(plan.label)")))
    }
}

/// Captures every message a test's `noticeSink`/`UndoJournal` notify closure
/// receives, in order.
@MainActor
private final class NoticeRecorder {
    private(set) var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

/// A fake `GhosttyPaneSurface`: records what `SessionViewModel` does to it,
/// with no real libghostty surface, `NSView`, or bridge process anywhere.
/// `detach()` has no hold/release: `SessionViewModel.performTeardown`
/// removes the pane's `ghosttySurfaces` entry SYNCHRONOUSLY, before ever
/// calling this method, so nothing a held `detach()` here could still be "in
/// the middle of" would leave that dictionary entry in a stale state for
/// another call to race against.
/// `@unchecked Sendable` for the same reason `GhosttySessionSurfaceHandle`
/// is: every touch of this class's state happens through its own
/// `@MainActor`-isolated methods, from tests that are themselves
/// `@MainActor`, even when a value crosses through `Task.value`.
@MainActor
private final class FakeGhosttyPaneSurface: GhosttyPaneSurface, @unchecked Sendable {
    let pane: PaneID
    private(set) var detachCallCount = 0
    private(set) var parkCallCount = 0
    private(set) var unparkCallCount = 0
    /// Test-driven, like a real bridge's status FIFO would flip it: starts
    /// `false`, and a test flips it directly to simulate the bridge's
    /// `paddock.first_frame` line landing.
    var hasFirstFrame = false

    init(pane: PaneID) {
        self.pane = pane
    }

    func detach() async {
        detachCallCount += 1
    }

    func park() {
        parkCallCount += 1
    }

    func unpark() {
        unparkCallCount += 1
    }
}

/// A fake `GhosttyPaneFactory` for `SessionViewModelTests`' ghostty attach
/// lifecycle tests -- records every `makeSurface` call (including the
/// `onUserInput` closure `SessionViewModel` hands it, so a test can invoke
/// it directly to pin the launcher-pristine contract) and hands back a
/// `FakeGhosttyPaneSurface` per pane. `makeSurface` can be held open one
/// call at a time, the same shape as `RecordingCommandClient.hold`/
/// `releaseNext`, so a test can pin a first attach mid-creation while a
/// second attach races it.
@MainActor
private final class FakeGhosttyPaneFactory: GhosttyPaneFactory {
    private(set) var makeSurfaceCalls: [PaneID] = []
    private(set) var surfaces: [PaneID: FakeGhosttyPaneSurface] = [:]
    private(set) var onUserInputHandlers: [PaneID: () -> Void] = [:]
    private(set) var onScreenActivityHandlers: [PaneID: (Int) -> Bool] = [:]
    private var holdEnabled = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    func hold() {
        holdEnabled = true
    }

    func releaseNext() {
        guard !pendingContinuations.isEmpty else { return }
        pendingContinuations.removeFirst().resume()
    }

    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        makeSurfaceCalls.append(pane)
        onUserInputHandlers[pane] = onUserInput
        onScreenActivityHandlers[pane] = onScreenActivity
        if holdEnabled {
            await withCheckedContinuation { pendingContinuations.append($0) }
        }
        let surface = FakeGhosttyPaneSurface(pane: pane)
        surfaces[pane] = surface
        return surface
    }
}

/// Records which panes' scroll feeds `SessionViewModel` arms and disarms.
@MainActor
private final class FakePaneScrollSubscriber: PaneScrollSubscribing {
    private(set) var subscribed: [PaneID] = []
    private(set) var unsubscribed: [PaneID] = []

    func subscribe(pane: PaneID) { subscribed.append(pane) }
    func unsubscribe(pane: PaneID) { unsubscribed.append(pane) }
}

/// `makeModel` plus one layout for `w1:t1` placing `w1:p1` at `rect` inside
/// a 120x40 area, so a test can move the pane's cell rect between updates.
private func makeModel(paneRect rect: CellRect) -> SessionModel {
    var model = makeModel()
    model.layouts[TabID(rawValue: "w1:t1")] = LayoutSnapshot(
        workspaceID: WorkspaceID(rawValue: "w1"),
        tabID: TabID(rawValue: "w1:t1"),
        zoomed: false,
        area: CellRect(x: 0, y: 0, width: 120, height: 40),
        focusedPaneID: PaneID(rawValue: "w1:p1"),
        panes: [PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: rect)],
        splits: []
    )
    return model
}

/// `makeModel` plus a layout for `w1:t1` with a root `.right` split (path
/// `[]`) over a 20x10 area and a nested `.down` split occupying the root's
/// own second child (path `[true]`) -- realistic herdr-shaped ids, so
/// `CanvasGeometry.splitPaths`'s id-parsed primary path resolves it the same
/// way production data would.
private func makeModelWithNestedSplit() -> SessionModel {
    var model = makeModel()
    let area = CellRect(x: 0, y: 0, width: 20, height: 10)
    model.layouts[TabID(rawValue: "w1:t1")] = LayoutSnapshot(
        workspaceID: WorkspaceID(rawValue: "w1"),
        tabID: TabID(rawValue: "w1:t1"),
        zoomed: false,
        area: area,
        focusedPaneID: PaneID(rawValue: "w1:p1"),
        panes: [PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: CellRect(x: 0, y: 0, width: 10, height: 10))],
        splits: [
            SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: area),
            SplitInfo(id: "split_1_1", direction: .down, ratio: 0.5, rect: CellRect(x: 10, y: 0, width: 10, height: 10)),
        ]
    )
    return model
}

private func stringParam(_ params: [String: JSONValue], _ key: String) -> String? {
    guard case .string(let value)? = params[key] else { return nil }
    return value
}

private func stringArrayParam(_ params: [String: JSONValue], _ key: String) -> [String]? {
    guard case .array(let values)? = params[key] else { return nil }
    return values.compactMap { element in
        guard case .string(let value) = element else { return nil }
        return value
    }
}

private func makeModel(
    focusedWorkspaceID: String = "w1",
    focusedTabID: String = "w1:t1",
    focusedPaneID: String = "w1:p1"
) -> SessionModel {
    let snapshotJSON = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(focusedWorkspaceID)","focused_tab_id":"\#(focusedTabID)","focused_pane_id":"\#(focusedPaneID)","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"orig","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[]}
    """#
    let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
    return SessionModel(snapshot: snapshot)
}

final class SessionViewModelTests: XCTestCase {
    @MainActor
    func testSelectionDefaultsToHerdrFocus() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModel(), connection: .live)

        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))
    }

    @MainActor
    func testSelectionSurvivesUnrelatedLayoutUpdate() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModel(), connection: .live)
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))

        // The user has since picked a DIFFERENT tab than herdr's own focus
        // -- paddock's selection only ever follows herdr's focus on a
        // CHANGE of it (see `testSelectionFollowsHerdrFocusedTabWhenItChanges`),
        // never unconditionally, so this override must survive.
        viewModel.select(tab: TabID(rawValue: "w1:t2"))

        // An unrelated layout_updated leaves herdr's OWN focused tab
        // untouched; the user's override must not be reset or clobbered
        // back to it.
        var updated = makeModel()
        updated.layouts[TabID(rawValue: "w1:t1")] = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:t1"),
            zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneID: PaneID(rawValue: "w1:p1"),
            panes: [],
            splits: []
        )
        viewModel.update(model: updated, connection: .live)

        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
        XCTAssertEqual(
            viewModel.selectedTabID, TabID(rawValue: "w1:t2"),
            "herdr's own focused tab did not change, so the user's own selection must persist")
    }

    /// The ruling this task's live tab-switch check depends on: paddock's
    /// selected tab now MIRRORS herdr's own focused tab live -- a tab switch
    /// is a warm re-host now, cheap enough to always follow, the same way
    /// the rest of the session already does. Only an actual CHANGE of
    /// herdr's focused tab moves the selection (see the test above for the
    /// complementary "no change, no move" half).
    @MainActor
    func testSelectionFollowsHerdrFocusedTabWhenItChanges() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModel(focusedTabID: "w1:t1"), connection: .live)
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))

        viewModel.update(model: makeModel(focusedTabID: "w1:t2"), connection: .live)

        XCTAssertEqual(
            viewModel.selectedTabID, TabID(rawValue: "w1:t2"),
            "herdr's focused tab changed, so paddock's selection follows it")
    }

    private static func twoWorkspaceModel() -> SessionModel {
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"one","number":1,"active_tab_id":"w1:t1","agent_status":"idle"},{"workspace_id":"w2","label":"two","number":2,"active_tab_id":"w2:t1","agent_status":"idle"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"a","number":1,"pane_count":1,"agent_status":"idle"},{"tab_id":"w2:t1","workspace_id":"w2","label":"b","number":1,"pane_count":1,"agent_status":"idle"},{"tab_id":"w2:t2","workspace_id":"w2","label":"c","number":2,"pane_count":1,"agent_status":"idle"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/tmp"}],"layouts":[]}
        """#
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    /// The strip shows only the selected workspace's tabs, so a tab picked
    /// from another workspace (a grid thumbnail, or its dwell) brings its
    /// workspace with it.
    @MainActor
    func testSelectingATabOfAnotherWorkspaceSelectsThatWorkspaceToo() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)

        viewModel.select(tab: TabID(rawValue: "w2:t2"))

        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w2:t2"))
        XCTAssertEqual(viewModel.tabsForSelectedWorkspace.map(\.tabID), [TabID(rawValue: "w2:t1"), TabID(rawValue: "w2:t2")])
    }

    @MainActor
    func testSelectingATabTheModelDoesNotListKeepsTheWorkspace() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)

        viewModel.select(tab: TabID(rawValue: "w9:t9"))

        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
    }

    @MainActor
    func testJumpingToAnotherWorkspacesTabFocusesItInHerdrAndShowsItsWorkspace() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)

        await viewModel.jumpToHerdr(tab: TabID(rawValue: "w2:t1"))

        let calls = await client.calls
        XCTAssertEqual(calls.map(\.method), ["tab.focus"])
        guard case .string(let tabID)? = calls.first?.params["tab_id"] else { return XCTFail("tab.focus carried no tab_id") }
        XCTAssertEqual(tabID, "w2:t1")
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
    }

    @MainActor
    func testJumpToHerdrPaneSendsPaneFocusWithExactID() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p9"))

        let calls = await client.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.method, "pane.focus")
        XCTAssertEqual(stringParam(calls.first?.params ?? [:], "pane_id"), "w1:p9")
    }

    @MainActor
    func testUnsupportedConnectionExposesProtocolMismatchBanner() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(
            model: nil,
            connection: .unsupported(.protocolTooOld(found: 19, required: 22))
        )

        XCTAssertEqual(viewModel.unsupportedBanner, ProtocolMismatch(found: 19, required: 22))
    }

    @MainActor
    func testTabsForSelectedWorkspaceReturnsThatWorkspacesTabs() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        var model = makeModel()
        let secondTab = TabRecord(
            tabID: TabID(rawValue: "w1:t2"), workspaceID: WorkspaceID(rawValue: "w1"),
            label: "second", number: 2, paneCount: 0, agentStatus: .unknown
        )
        model.tabs[WorkspaceID(rawValue: "w1")]?.append(secondTab)
        viewModel.update(model: model, connection: .live)

        XCTAssertEqual(
            viewModel.tabsForSelectedWorkspace.map(\.tabID),
            [TabID(rawValue: "w1:t1"), TabID(rawValue: "w1:t2")]
        )
    }

    @MainActor
    func testTabsForSelectedWorkspaceEmptyWhenNoSelectionYet() {
        // No update() call at all: selectedWorkspaceID stays nil.
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        XCTAssertEqual(viewModel.tabsForSelectedWorkspace, [])
    }

    @MainActor
    func testTabsForSelectedWorkspaceEmptyWhenWorkspaceHasNoTabs() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        var model = makeModel()
        model.workspaces.append(WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: "w2"), label: "empty", number: 2,
            activeTabID: TabID(rawValue: "w2:t1"), agentStatus: .unknown
        ))
        viewModel.update(model: model, connection: .live)
        viewModel.select(workspace: WorkspaceID(rawValue: "w2"))

        XCTAssertEqual(viewModel.tabsForSelectedWorkspace, [])
    }

    @MainActor
    func testSelectedLayoutReturnsLayoutForSelectedTab() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        var model = makeModel()
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
            zoomed: false, area: CellRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneID: PaneID(rawValue: "w1:p1"), panes: [], splits: []
        )
        model.layouts[TabID(rawValue: "w1:t1")] = layout
        viewModel.update(model: model, connection: .live)

        XCTAssertEqual(viewModel.selectedLayout, layout)
    }

    @MainActor
    func testSelectedLayoutNilWhenNoTabSelected() {
        // No update() call at all: selectedTabID stays nil.
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        XCTAssertNil(viewModel.selectedLayout)
    }

    @MainActor
    func testSelectedLayoutNilWhenModelHasNoLayoutForSelectedTab() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        // makeModel()'s snapshot ships an empty "layouts" array.
        viewModel.update(model: makeModel(), connection: .live)

        XCTAssertNil(viewModel.selectedLayout)
    }

    @MainActor
    func testPaneCountForWorkspaceCountsOnlyThatWorkspacesPanes() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        var model = makeModel()
        model.panes[PaneID(rawValue: "w1:p2")] = PaneRecord(
            paneID: PaneID(rawValue: "w1:p2"), workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:t1"), focused: false, agentStatus: .unknown,
            revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
        model.panes[PaneID(rawValue: "w2:p1")] = PaneRecord(
            paneID: PaneID(rawValue: "w2:p1"), workspaceID: WorkspaceID(rawValue: "w2"),
            tabID: TabID(rawValue: "w2:t1"), focused: false, agentStatus: .unknown,
            revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
        viewModel.update(model: model, connection: .live)

        XCTAssertEqual(viewModel.paneCount(for: WorkspaceID(rawValue: "w1")), 2)
        XCTAssertEqual(viewModel.paneCount(for: WorkspaceID(rawValue: "w2")), 1)
    }

    @MainActor
    func testPaneCountForWorkspaceZeroWhenWorkspaceHasNoPanes() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModel(), connection: .live)

        XCTAssertEqual(viewModel.paneCount(for: WorkspaceID(rawValue: "w2")), 0)
    }

    @MainActor
    func testPaneCountForWorkspaceZeroWhenModelNil() {
        // No update() call at all: model stays nil.
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        XCTAssertEqual(viewModel.paneCount(for: WorkspaceID(rawValue: "w1")), 0)
    }

    @MainActor
    func testJumpToHerdrPaneSetsOptimisticFocusImmediately() async {
        let client = RecordingCommandClient()
        await client.hold()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: makeModel(), connection: .live)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p1"))

        let task = Task { await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p2")) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // The ring target moved with no model mutation at all: the request
        // is still parked inside `requestRaw`, held by the test double.
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(viewModel.model?.focusedPaneID, PaneID(rawValue: "w1:p1"))

        await client.releaseNext()
        await task.value
    }

    @MainActor
    func testModelEchoClearsOptimisticFocus() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)

        Task { await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p2")) }

        // Echo: the model catches up to the optimistic prediction.
        viewModel.update(model: makeModel(focusedPaneID: "w1:p2"), connection: .live)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p2"))

        // Prove the optimistic value was actually cleared, not just
        // coincidentally equal to the model: a later, unrelated model change
        // moving focus elsewhere must now be reflected immediately, which
        // only happens if nothing is still overriding the model's field.
        viewModel.update(model: makeModel(focusedPaneID: "w1:p3"), connection: .live)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p3"))
    }

    @MainActor
    func testJumpToHerdrPaneRevertsOptimisticOnFailure() async {
        let viewModel = SessionViewModel(client: FailingCommandClient())
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)

        await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p2"))

        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p1"))
    }

    @MainActor
    func testSecondClickMidFlightSupersedesFirst() async {
        let client = RecordingCommandClient()
        await client.hold()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)

        let firstTask = Task { await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p2")) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p2"))

        let secondTask = Task { await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p3")) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p3"))

        // Let the (stale) first request finish -- its success must not
        // touch the optimistic value at all, let alone clear it back to p1.
        await client.releaseNext()
        await firstTask.value
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p3"))

        await client.releaseNext()
        await secondTask.value
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p3"))
    }

    // MARK: - new-pane harness launcher provenance

    @MainActor
    func testSplitRightSendsExpectedParamsAndRegistersTheNewPaneAsPristine() async {
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client)

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))

        let calls = await client.calls
        let splitCall = try? XCTUnwrap(calls.first { $0.method == "pane.split" })
        XCTAssertEqual(stringParam(splitCall?.params ?? [:], "target_pane_id"), "w1:p1")
        XCTAssertEqual(stringParam(splitCall?.params ?? [:], "direction"), "right")
        XCTAssertNil(splitCall?.params["cwd"] ?? nil, "cwd is omitted so herdr follows the source pane's own cwd")

        XCTAssertTrue(viewModel.isPristineLauncherPane(PaneID(rawValue: "w1:p2")))
        XCTAssertFalse(
            viewModel.isPristineLauncherPane(PaneID(rawValue: "w1:p1")),
            "the SOURCE pane was never paddock-created; only the new one is registered"
        )
    }

    /// The Enter must ride `keys`, never a newline inside `text`: herdr wraps
    /// a non-empty `text` in a bracketed-paste sequence whenever the pane's
    /// program enabled it, and a newline inside that bracket is a literal
    /// newline in the line editor, so the harness name would be typed and
    /// never run.
    @MainActor
    func testLaunchHarnessSubmitsWithAnEnterKeyNotANewlineInsideTheText() async throws {
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client)
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        XCTAssertTrue(viewModel.isPristineLauncherPane(newPane))

        await viewModel.launchHarness("claude", in: newPane)

        let calls = await client.calls
        let sendCall = try XCTUnwrap(calls.last { $0.method == "pane.send_input" })
        XCTAssertEqual(stringParam(sendCall.params, "text"), "claude")
        XCTAssertEqual(stringArrayParam(sendCall.params, "keys"), ["Enter"])
        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane), "launching hides the overlay like a real keystroke would")
    }

    /// A launcher click can land on a pane that is NOT the resolved-focused
    /// one (split right, click back into the original pane, then click the
    /// overlay on the new pane). Only the focused pane's surface accepts
    /// keystrokes, so `launchHarness` must reach the pane over
    /// `pane.send_input` regardless of focus, never through the surface.
    @MainActor
    func testLaunchHarnessReachesAnUnfocusedPaneViaSendInput() async throws {
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory)
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        // No focus is ever set on this view model, so the new pane is never
        // the resolved-focused one for the whole test.
        _ = await viewModel.attachPane(newPane)
        XCTAssertNotEqual(viewModel.resolvedFocusedPaneID, newPane)
        XCTAssertTrue(viewModel.isPristineLauncherPane(newPane))

        await viewModel.launchHarness("claude", in: newPane)

        let calls = await client.calls
        let sendCall = try XCTUnwrap(calls.last { $0.method == "pane.send_input" })
        XCTAssertEqual(
            stringParam(sendCall.params, "text"), "claude",
            "the command reaches the pane over pane.send_input, focus-independent")
        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane))
    }

    // MARK: - ghostty pane attach (every visible pane, one surface for its whole life)

    @MainActor
    func testAttachIsANoOpWithNoFactoryInjected() async {
        let viewModel = SessionViewModel(client: RecordingCommandClient())

        let surface = await viewModel.attachPane(PaneID(rawValue: "w1:p1"))

        XCTAssertNil(surface)
    }

    @MainActor
    func testAttachCreatesExactlyOneSurfacePerPane() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let first = await viewModel.attachPane(pane)
        let second = await viewModel.attachPane(pane)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "a second attach must never spawn a second surface for the same pane")
        XCTAssertTrue(first === second, "the same surface instance is handed back to a second attach")
    }

    // MARK: - per-pane scroll feed (armed while visible only)

    @MainActor
    func testAttachArmsTheScrollFeedAndParkDisarmsIt() async throws {
        let factory = FakeGhosttyPaneFactory()
        let scroll = FakePaneScrollSubscriber()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory, paneScrollSubscriber: scroll)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane)
        XCTAssertEqual(scroll.subscribed, [pane])
        XCTAssertTrue(scroll.unsubscribed.isEmpty)

        await viewModel.detachPane(pane)
        XCTAssertEqual(scroll.unsubscribed, [pane])

        _ = await viewModel.attachPane(pane)
        XCTAssertEqual(scroll.subscribed, [pane, pane], "a warm reattach re-arms the feed")
    }

    @MainActor
    func testAPaneHerdrClosesHasItsScrollFeedDisarmed() async throws {
        let factory = FakeGhosttyPaneFactory()
        let scroll = FakePaneScrollSubscriber()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory, paneScrollSubscriber: scroll)
        let pane = PaneID(rawValue: "w1:p1")
        viewModel.update(model: makeModel(), connection: .live)
        _ = await viewModel.attachPane(pane)

        var closed = makeModel()
        closed.panes.removeValue(forKey: pane)
        viewModel.update(model: closed, connection: .live)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertEqual(scroll.unsubscribed, [pane])
    }

    // MARK: - warm surface pool (park, not teardown, across a tab switch)

    /// The core of the pool: `detachPane` PARKS rather than tearing down --
    /// the surface stays alive and reachable, never `detach()`-ed, and gets
    /// told to park (observe mode, occluded).
    @MainActor
    func testDetachParksTheSurfaceRatherThanTearingItDown() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        await viewModel.detachPane(pane)

        XCTAssertEqual(surface.detachCallCount, 0, "a park must never tear the surface down")
        XCTAssertEqual(surface.parkCallCount, 1)
        XCTAssertNotNil(viewModel.ghosttySurface(for: pane), "a parked surface must still be reachable -- it is what makes a warm reattach possible")
    }

    /// Reattaching a PARKED pane returns the SAME surface, with no second
    /// `makeSurface` call -- the whole point of the pool: a tab switch back
    /// re-hosts warm content instead of spawning a fresh bridge/PTY.
    @MainActor
    func testReattachAfterParkReturnsTheSameSurfaceWithNoNewMakeSurfaceCall() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let first = await viewModel.attachPane(pane)
        await viewModel.detachPane(pane)
        let second = await viewModel.attachPane(pane)

        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "a reattach after a park must never create a second surface")
        XCTAssertTrue(first === second, "the same surface instance comes back")
        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.unparkCallCount, 1, "a warm reattach unparks the surface")
    }

    /// The warm cap: parking a 13th pane (cap is 12) evicts the FIRST
    /// PARKED one for real (`detach()`), leaving the rest -- including the
    /// newest -- warm and reachable. Attached in ASCENDING order but parked
    /// in the REVERSE (descending) order specifically so attach order and
    /// park order disagree on which pane is "oldest": only park order may
    /// decide eviction, never attach order.
    @MainActor
    func testExceedingTheWarmCapTearsDownTheOldestParkedPaneNotTheOldestAttached() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let panes = (1...13).map { PaneID(rawValue: "w1:p\($0)") }

        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
        for pane in panes.reversed() {
            await viewModel.detachPane(pane)
        }

        let firstParked = panes[12] // w1:p13 -- attached LAST, but parked FIRST
        let lastParked = panes[0] // w1:p1 -- attached FIRST, but parked LAST
        let evicted = try XCTUnwrap(factory.surfaces[firstParked])
        XCTAssertEqual(evicted.detachCallCount, 1, "the FIRST PARKED pane must be evicted, regardless of attach order")
        XCTAssertNil(viewModel.ghosttySurface(for: firstParked))

        let newest = try XCTUnwrap(factory.surfaces[lastParked])
        XCTAssertEqual(newest.detachCallCount, 0, "the pane parked LAST -- even though it was attached FIRST -- must stay warm")
        XCTAssertNotNil(viewModel.ghosttySurface(for: lastParked))

        for pane in panes where pane != firstParked {
            let surface = try XCTUnwrap(factory.surfaces[pane])
            XCTAssertEqual(surface.detachCallCount, 0, "every pane but the first-parked one stays warm")
        }
    }

    /// The evicted pane has nothing left in the pool: a later reattach under
    /// the SAME id creates a brand new surface, never reuses the torn-down
    /// one.
    @MainActor
    func testEvictedPaneReattachesColdWithANewSurface() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let panes = (1...13).map { PaneID(rawValue: "w1:p\($0)") }

        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
        for pane in panes {
            await viewModel.detachPane(pane)
        }
        XCTAssertEqual(factory.makeSurfaceCalls.count, 13)
        let evictedPane = panes[0]
        XCTAssertNil(viewModel.ghosttySurface(for: evictedPane), "the oldest-parked pane was evicted")

        let reattached = await viewModel.attachPane(evictedPane)

        XCTAssertNotNil(reattached)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 14, "the evicted pane's reattach must create a NEW surface, not reuse the torn-down one")
    }

    /// a park and an attach for the SAME pane, both fired as independent,
    /// unawaited `Task { ... }` closures in the SAME main-actor turn -- the
    /// exact real shape of `PaneCellView.onDisappear`'s `Task { await
    /// viewModel.detachPane(...) }` racing a fresh `.task(id:)` firing
    /// `attachPane` for the same pane before the outgoing park has settled
    /// (a fast tab-switch-back) -- must never leave the pane both VISIBLE
    /// (attached) and still tracked as PARKED. That combination is exactly
    /// what would let a later, unrelated eviction tear down a pane that is
    /// actually on screen. This is deterministic, not a timing gamble: the
    /// two calls share `paneWork[pane]`'s chain, so whichever of the two
    /// underlying steps (`performPark`/`performAttach`) runs SECOND settles
    /// the pane's true state -- the fix is that `performAttach` re-removes
    /// from `parkedPanes` itself rather than trusting `attachPane`'s own
    /// synchronous (pre-chain) removal, which can run before `performPark`
    /// ever appends.
    @MainActor
    func testInterleavedParkAndAttachForTheSamePaneNeverLeavesItBothVisibleAndParked() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")
        _ = await viewModel.attachPane(pane)

        // Neither call is awaited before the next fires -- both `Task { }`
        // closures are simply created back to back, exactly like the two
        // independent SwiftUI-driven call sites do in production.
        let parkTask = Task { await viewModel.detachPane(pane) }
        let attachTask = Task { _ = await viewModel.attachPane(pane) }
        await parkTask.value
        await attachTask.value

        // Whichever of the two settles last, the pane must end up NOT
        // eligible for warm eviction while it is reachable/visible: prove
        // it by parking 12 MORE panes afterward (the full warm cap) and
        // confirming this one is never swept up as if it were still parked.
        let otherPanes = (2...13).map { PaneID(rawValue: "w1:p\($0)") }
        for other in otherPanes {
            _ = await viewModel.attachPane(other)
        }
        for other in otherPanes {
            await viewModel.detachPane(other)
        }

        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(
            surface.detachCallCount, 0,
            "a pane left visible by the interleaving must never be torn down by an unrelated warm-cap eviction")
        XCTAssertNotNil(viewModel.ghosttySurface(for: pane))
    }

    /// A pane re-keyed across workspaces (`.paneMoved` at the reducer level,
    /// `PaneMovedPayload`) leaves its OLD id behind entirely -- from the
    /// pool's perspective that is indistinguishable from herdr closing the
    /// old id outright: it is torn down for real once it vanishes from the
    /// model, and the NEW id, when it attaches, gets a brand new (cold)
    /// surface -- the pool never conflates the two.
    @MainActor
    func testPaneReKeyedAcrossWorkspacesTearsDownTheOldIDAndAttachesTheNewIDCold() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let oldPane = PaneID(rawValue: "w1:p2")
        var modelBefore = makeModel()
        modelBefore.panes[oldPane] = PaneRecord(
            paneID: oldPane, workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
            focused: false, agentStatus: .unknown, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
        viewModel.update(model: modelBefore, connection: .live)

        _ = await viewModel.attachPane(oldPane)
        let oldSurface = try XCTUnwrap(factory.surfaces[oldPane])
        await viewModel.detachPane(oldPane)
        XCTAssertEqual(oldSurface.detachCallCount, 0, "parked, not torn down, yet")

        // The pane re-keys to a new workspace/id -- the OLD id vanishes from
        // the model entirely (it is never reported again under that id).
        let newPane = PaneID(rawValue: "w2:p9")
        var modelAfter = makeModel()
        modelAfter.panes[newPane] = PaneRecord(
            paneID: newPane, workspaceID: WorkspaceID(rawValue: "w2"), tabID: TabID(rawValue: "w2:t1"),
            focused: false, agentStatus: .unknown, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
        viewModel.update(model: modelAfter, connection: .live)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertEqual(oldSurface.detachCallCount, 1, "the old id must be torn down for real once it vanishes from the model")
        XCTAssertNil(viewModel.ghosttySurface(for: oldPane))

        let newSurface = await viewModel.attachPane(newPane)
        XCTAssertNotNil(newSurface)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 2, "the new id attaches cold -- a brand new surface, never reusing the old id's")
    }

    /// M1/pool integration: closing a whole TAB tears down every one of its
    /// parked panes, not just an individually-closed pane -- the fixed
    /// `removeTab` reducer drops every pane belonging to the closed tab from
    /// `model.panes` in one shot, and the pool's own `reconcileClosedPanes`
    /// (which does not care WHY a pane vanished) reacts identically either
    /// way.
    @MainActor
    func testClosingATabTearsDownAllItsParkedPanes() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let paneA = PaneID(rawValue: "w1:p2")
        let paneB = PaneID(rawValue: "w1:p3")
        var modelWithTab = makeModel()
        for pane in [paneA, paneB] {
            modelWithTab.panes[pane] = PaneRecord(
                paneID: pane, workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t2"),
                focused: false, agentStatus: .unknown, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
            )
        }
        viewModel.update(model: modelWithTab, connection: .live)

        _ = await viewModel.attachPane(paneA)
        _ = await viewModel.attachPane(paneB)
        let surfaceA = try XCTUnwrap(factory.surfaces[paneA])
        let surfaceB = try XCTUnwrap(factory.surfaces[paneB])
        await viewModel.detachPane(paneA)
        await viewModel.detachPane(paneB)

        // The tab (w1:t2) closes: both its panes vanish from the model in
        // one shot, the way the fixed `removeTab` reducer now behaves.
        viewModel.update(model: makeModel(), connection: .live)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertEqual(surfaceA.detachCallCount, 1)
        XCTAssertEqual(surfaceB.detachCallCount, 1)
        XCTAssertNil(viewModel.ghosttySurface(for: paneA))
        XCTAssertNil(viewModel.ghosttySurface(for: paneB))
    }

    /// A pane herdr no longer reports (missing from a later `update`) is
    /// torn down for real regardless of the warm cap -- it has nothing left
    /// to come back to.
    @MainActor
    func testAPaneClosedInHerdrIsTornDownRegardlessOfWarmth() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let closingPane = PaneID(rawValue: "w1:p2")
        var modelWithBothPanes = makeModel()
        modelWithBothPanes.panes[closingPane] = PaneRecord(
            paneID: closingPane, workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
            focused: false, agentStatus: .unknown, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
        viewModel.update(model: modelWithBothPanes, connection: .live)

        _ = await viewModel.attachPane(closingPane)
        let surface = try XCTUnwrap(factory.surfaces[closingPane])
        await viewModel.detachPane(closingPane)
        XCTAssertEqual(surface.detachCallCount, 0, "parked, not torn down, until herdr stops reporting it")

        // herdr closed the pane: the next snapshot still reports `w1:p1` but
        // no longer this one.
        viewModel.update(model: makeModel(), connection: .live)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertEqual(surface.detachCallCount, 1, "a pane herdr no longer reports must be torn down for real")
        XCTAssertNil(viewModel.ghosttySurface(for: closingPane))
    }

    /// The seam `PaneCellView` reads for its card-to-surface crossfade: a
    /// fake surface's `hasFirstFrame` flips exactly like the real bridge's
    /// status FIFO would, and a warm reattach comes back with that flip
    /// already reflected -- never reset, so a re-hosted pane never shows its
    /// card again.
    @MainActor
    func testHasFirstFrameSurvivesAParkAndReattach() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertFalse(surface.hasFirstFrame, "a cold attach starts without a first frame -- the card shows")

        surface.hasFirstFrame = true
        await viewModel.detachPane(pane)
        let reattached = await viewModel.attachPane(pane)

        XCTAssertTrue(reattached === surface)
        XCTAssertEqual(reattached?.hasFirstFrame, true, "a warm reattach's surface already carries its first frame -- the card never comes back")
    }

    /// A second attach arriving while the FIRST-EVER attach for a pane is
    /// still awaiting `makeSurface` must not spawn (or leave reachable) a
    /// second surface.
    @MainActor
    func testASecondAttachDuringAnInFlightFirstAttachLeaksNoStaleSurface() async throws {
        let factory = FakeGhosttyPaneFactory()
        factory.hold()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let firstTask = Task { await viewModel.attachPane(pane) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let secondTask = Task { await viewModel.attachPane(pane) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        factory.releaseNext()
        let firstSurface = await firstTask.value
        let secondSurface = await secondTask.value

        XCTAssertNotNil(firstSurface, "the first-ever attach for this pane returns the real surface")
        XCTAssertNotNil(secondSurface, "the second attach resolves too, once creation settles")
        XCTAssertTrue(firstSurface === secondSurface, "no stale second surface may exist for the same pane")
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "only ONE makeSurface call, even though a second attach arrived mid-creation")

        let surface = try XCTUnwrap(factory.surfaces[pane])

        // The actual discriminator: without `paneWork` serialization, the
        // second attach could race ahead of the held creation and see no
        // surface yet, spawning its OWN second one.
        let noop = await viewModel.attachPane(pane)
        XCTAssertTrue(noop === surface)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "still only one surface ever created for this pane")
    }

    /// The launcher-pristine contract's ghostty half: a keystroke reported
    /// through the ghostty input seam (`onUserInput`, the closure
    /// `GhosttyPaneFactory.makeSurface` is handed) must hide the launcher.
    @MainActor
    func testGhosttyPaneKeystrokeThroughInputSeamHidesTheLauncher() async throws {
        let factory = FakeGhosttyPaneFactory()
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p2")

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane), "a freshly paddock-created pane starts pristine")

        _ = await viewModel.attachPane(pane)
        let onUserInput = try XCTUnwrap(factory.onUserInputHandlers[pane])

        onUserInput()

        XCTAssertFalse(
            viewModel.isPristineLauncherPane(pane),
            "a keystroke reported through the ghostty seam must hide the launcher"
        )
    }

    /// The launcher-pristine contract's OTHER half: a pane whose program
    /// prints real output, never typed into, also hides the overlay.
    /// `GhosttySession` reports this through `onScreenActivity`, gated on
    /// `isPristineLauncherPane` at the ViewModel end so a call arriving
    /// after the pane is already hidden (by either path) is a cheap no-op
    /// that also tells the surface to stop reporting.
    @MainActor
    func testScreenActivityThroughGhosttySeamHidesTheLauncherAndStopsFurtherReporting() async throws {
        let factory = FakeGhosttyPaneFactory()
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p2")

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane))

        _ = await viewModel.attachPane(pane)
        let onScreenActivity = try XCTUnwrap(factory.onScreenActivityHandlers[pane])

        // At most the bare prompt (<=2 non-empty rows): still pristine, and
        // the surface is told to keep reporting.
        XCTAssertTrue(onScreenActivity(2), "still just the prompt -- keep polling")
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane))

        // Real output beyond the prompt rows: hides the launcher, and tells
        // the surface to stop.
        XCTAssertFalse(onScreenActivity(3), "output beyond the prompt hides the pane -- stop polling")
        XCTAssertFalse(viewModel.isPristineLauncherPane(pane))

        // A later call (the surface's own throttle firing once more before
        // it notices the stop signal) must stay a harmless no-op.
        XCTAssertFalse(onScreenActivity(10))
    }

    // MARK: - context-menu commands (split down, close, right-click routing)

    @MainActor
    func testSplitDownSendsDownDirectionAndRegistersTheNewPaneAsPristine() async {
        let client = StubSplitCommandClient(newPaneID: "w1:p3")
        let viewModel = SessionViewModel(client: client)

        await viewModel.splitDown(from: PaneID(rawValue: "w1:p1"))

        let calls = await client.calls
        let splitCall = try? XCTUnwrap(calls.first { $0.method == "pane.split" })
        XCTAssertEqual(stringParam(splitCall?.params ?? [:], "target_pane_id"), "w1:p1")
        XCTAssertEqual(stringParam(splitCall?.params ?? [:], "direction"), "down")
        XCTAssertTrue(viewModel.isPristineLauncherPane(PaneID(rawValue: "w1:p3")))
    }

    @MainActor
    func testClosePaneSendsPaneCloseWithPaneID() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)

        await viewModel.closePane(PaneID(rawValue: "w1:p1"))

        let calls = await client.calls
        let closeCall = try? XCTUnwrap(calls.first { $0.method == "pane.close" })
        XCTAssertEqual(stringParam(closeCall?.params ?? [:], "pane_id"), "w1:p1")
    }

    @MainActor
    func testClosePaneRoutesThroughThePlanExecutorAndRecordsInTheJournal() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })

        await viewModel.closePane(PaneID(rawValue: "w1:p1"))

        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.closePane(PaneID(rawValue: "w1:p1"))], label: "Close pane")])
        XCTAssertTrue(journal.canUndo)
    }

    @MainActor
    func testSetSplitRatioRoutesThroughThePlanExecutorAndRecordsInTheJournal() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let model = makeModelWithNestedSplit()
        let journal = UndoJournal(executor: executor, model: { model }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        viewModel.update(model: model, connection: .live)

        await viewModel.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true], ratio: 0.62)

        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true], ratio: 0.62)], label: "Resize split")])
        XCTAssertTrue(journal.canUndo)
    }

    @MainActor
    func testSetSplitRatioDeclinesWhenNoDividerExistsAtThatPathAnymore() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let model = makeModelWithNestedSplit()
        let journal = UndoJournal(executor: executor, model: { model }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        viewModel.update(model: model, connection: .live)

        // A path the seeded layout's own split tree does not resolve --
        // herdr reshaped the tab mid-drag, say.
        await viewModel.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [true, true], ratio: 0.62)

        XCTAssertTrue(executor.executedPlans.isEmpty, "no op reaches the executor for a split that no longer exists")
        XCTAssertFalse(journal.canUndo)
    }

    @MainActor
    func testSetSplitRatioWithNoPlanExecutorSendsNoWireTraffic() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)

        await viewModel.setSplitRatio(tab: TabID(rawValue: "w1:t1"), path: [], ratio: 0.5)

        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testPerformWithNoPlanExecutorReturnsNotAttemptedWithoutTouchingAnything() async {
        let viewModel = SessionViewModel(client: RecordingCommandClient())

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .paneInterior(PaneID(rawValue: "w1:p1")))

        XCTAssertEqual(outcome, .notAttempted)
    }

    @MainActor
    func testPerformWithNoModelYetReturnsNotAttemptedWithoutTouchingTheExecutor() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { nil }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .paneInterior(PaneID(rawValue: "w1:p1")))

        XCTAssertEqual(outcome, .notAttempted)
        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertTrue(notices.messages.isEmpty)
    }

    @MainActor
    func testPerformRoutesASuccessfulPlanToTheJournal() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        var model = makeModel()
        model.tabs[WorkspaceID(rawValue: "w1")]?.append(TabRecord(
            tabID: TabID(rawValue: "w1:t2"), workspaceID: WorkspaceID(rawValue: "w1"),
            label: "second", number: 2, paneCount: 0, agentStatus: .unknown
        ))
        viewModel.update(model: model, connection: .live)

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        XCTAssertEqual(executor.executedPlans.map(\.label), ["Move pane into tab"])
        XCTAssertTrue(journal.canUndo)
        XCTAssertEqual(journal.undoLabel, "Move pane into tab")
        XCTAssertTrue(notices.messages.isEmpty)
        XCTAssertEqual(outcome, .committed)
    }

    @MainActor
    func testPerformRoutesANoOpPlanBackWithoutTouchingTheExecutorOrTheNoticeSink() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        viewModel.update(model: makeModel(), connection: .live)

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .paneInterior(PaneID(rawValue: "w1:p1")))

        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertFalse(journal.canUndo)
        XCTAssertTrue(notices.messages.isEmpty)
        XCTAssertEqual(outcome, .noOp)
    }

    @MainActor
    func testPerformRoutesAnInvalidCombinationToTheNoticeSinkWithoutTouchingTheExecutor() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        viewModel.update(model: makeModel(), connection: .live)

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .workspaceRail(insertIndex: 0))

        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertFalse(journal.canUndo)
        XCTAssertEqual(notices.messages, ["Can't move there"])
        XCTAssertEqual(outcome, .rejected("Can't move there"))
    }

    @MainActor
    func testPerformRoutesAnExecutorFailureToTheNoticeSink() async {
        let executor = FakePlanExecutor()
        executor.nextResult = .failure(OpFailure(
            failedOp: .closePane(PaneID(rawValue: "w1:p1")), code: "boom", message: "boom happened",
            executed: [], partialInverse: OpPlan(ops: [], label: "x")
        ))
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        var model = makeModel()
        model.tabs[WorkspaceID(rawValue: "w1")]?.append(TabRecord(
            tabID: TabID(rawValue: "w1:t2"), workspaceID: WorkspaceID(rawValue: "w1"),
            label: "second", number: 2, paneCount: 0, agentStatus: .unknown
        ))
        viewModel.update(model: model, connection: .live)

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        XCTAssertFalse(journal.canUndo)
        XCTAssertEqual(notices.messages, ["Move pane into tab failed: boom happened"])
        XCTAssertEqual(outcome, .rejected("Move pane into tab failed: boom happened"))
    }

    @MainActor
    func testLayoutExportRefreshesOnlyWhenThatTabsSignatureChangesThroughUpdate() async {
        let tabID = TabID(rawValue: "w1:t1")
        let paneID = PaneID(rawValue: "w1:p1")
        let exported = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: tabID,
            zoomed: false,
            focusedPaneID: paneID,
            root: .pane(ExportedLayoutPane(paneID: paneID))
        )
        let layoutExportClient = FakeLayoutExportClient(result: exported)
        let viewModel = SessionViewModel(client: RecordingCommandClient(), layoutExportClient: layoutExportClient)

        func modelWithLayout(_ layout: LayoutSnapshot) -> SessionModel {
            var model = makeModel()
            model.layouts[tabID] = layout
            return model
        }
        let singlePane = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: tabID, zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: paneID,
            panes: [PaneRect(paneID: paneID, focused: true, rect: CellRect(x: 0, y: 0, width: 80, height: 24))],
            splits: []
        )

        // The seam PaddockApp's `.onChange(of: herdrStore.model)` calls into:
        // the first update for a tab always fetches.
        viewModel.update(model: modelWithLayout(singlePane), connection: .live)
        await viewModel.waitForLayoutExportsIdle()
        var calls = await layoutExportClient.calls
        XCTAssertEqual(calls, [tabID])
        XCTAssertEqual(viewModel.exportedLayout(for: tabID), exported)

        // Same layout again: unchanged signature, no refetch.
        viewModel.update(model: modelWithLayout(singlePane), connection: .live)
        await viewModel.waitForLayoutExportsIdle()
        calls = await layoutExportClient.calls
        XCTAssertEqual(calls, [tabID])

        // A real layout change (a split appears): signature changes, refetch.
        let splitLayout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: tabID, zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: paneID,
            panes: [
                PaneRect(paneID: paneID, focused: true, rect: CellRect(x: 0, y: 0, width: 40, height: 24)),
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: CellRect(x: 40, y: 0, width: 40, height: 24)),
            ],
            splits: [SplitInfo(id: "s1", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 80, height: 24))]
        )
        viewModel.update(model: modelWithLayout(splitLayout), connection: .live)
        await viewModel.waitForLayoutExportsIdle()
        calls = await layoutExportClient.calls
        XCTAssertEqual(calls, [tabID, tabID])
    }
    // MARK: - following a pane after a drop

    private static func focusedPaneIDs(_ client: RecordingCommandClient) async -> [String] {
        await client.calls.compactMap { call in
            guard call.method == "pane.focus", case .string(let id)? = call.params["pane_id"] else { return nil }
            return id
        }
    }

    @MainActor
    private func viewModelWithSecondTab(executor: FakePlanExecutor, client: RecordingCommandClient) -> SessionViewModel {
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { _ in })
        let viewModel = SessionViewModel(client: client, planExecutor: executor, undoJournal: journal)
        var model = makeModel()
        model.tabs[WorkspaceID(rawValue: "w1")]?.append(TabRecord(
            tabID: TabID(rawValue: "w1:t2"), workspaceID: WorkspaceID(rawValue: "w1"),
            label: "second", number: 2, paneCount: 0, agentStatus: .unknown
        ))
        viewModel.update(model: model, connection: .live)
        return viewModel
    }

    @MainActor
    func testAPaneDroppedIntoAnotherTabIsFocusedSoPaddockFollowsIt() async {
        let executor = FakePlanExecutor()
        let client = RecordingCommandClient()
        let viewModel = viewModelWithSecondTab(executor: executor, client: client)

        let outcome = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        XCTAssertEqual(outcome, .committed)
        let focused = await Self.focusedPaneIDs(client)
        XCTAssertEqual(focused, ["w1:p1"])
    }

    /// A move across workspaces re-keys the pane, so the id herdr assigned is
    /// the only one that still names it.
    @MainActor
    func testFollowingARekeyedPaneFocusesTheIdHerdrAssigned() async {
        let executor = FakePlanExecutor()
        executor.nextResult = .success(ExecutedPlan(
            plan: OpPlan(ops: [], label: "Move pane into tab"),
            inverse: OpPlan(ops: [], label: "Undo Move pane into tab"),
            paneIDRemap: [PaneID(rawValue: "w1:p1"): PaneID(rawValue: "w2:p9")]
        ))
        let client = RecordingCommandClient()
        let viewModel = viewModelWithSecondTab(executor: executor, client: client)

        _ = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        let focused = await Self.focusedPaneIDs(client)
        XCTAssertEqual(focused, ["w2:p9"])
    }

    @MainActor
    func testAFailedDropFollowsNothing() async {
        let executor = FakePlanExecutor()
        executor.nextResult = .failure(OpFailure(
            failedOp: .focusTab(TabID(rawValue: "w1:t2")), code: "boom", message: "boom", executed: [], partialInverse: OpPlan(ops: [], label: "")
        ))
        let client = RecordingCommandClient()
        let viewModel = viewModelWithSecondTab(executor: executor, client: client)

        _ = await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        let focused = await Self.focusedPaneIDs(client)
        XCTAssertEqual(focused, [])
    }

    func testOnlyDropsThatLeaveTheTabFollowThePane() {
        let pane = PaneID(rawValue: "w1:p1")
        XCTAssertTrue(DropTarget.tabThumbnail(TabID(rawValue: "w1:t2")).takesThePaneOffItsTab)
        XCTAssertTrue(DropTarget.newTab(WorkspaceID(rawValue: "w1")).takesThePaneOffItsTab)
        XCTAssertTrue(DropTarget.workspaceThumbnail(WorkspaceID(rawValue: "w2")).takesThePaneOffItsTab)
        XCTAssertTrue(DropTarget.newWorkspace.takesThePaneOffItsTab)
        XCTAssertFalse(DropTarget.paneEdge(pane, .left).takesThePaneOffItsTab)
        XCTAssertFalse(DropTarget.paneInterior(pane).takesThePaneOffItsTab)
        XCTAssertFalse(DropTarget.tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0).takesThePaneOffItsTab)
        XCTAssertFalse(DropTarget.workspaceRail(insertIndex: 0).takesThePaneOffItsTab)
        XCTAssertFalse(DropTarget.allWorkspaces.takesThePaneOffItsTab)
        XCTAssertFalse(DropTarget.moreTabs(WorkspaceID(rawValue: "w1")).takesThePaneOffItsTab)
    }

}
