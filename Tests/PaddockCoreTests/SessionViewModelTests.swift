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

/// Shared, thread-safe log of `(pane, mode)` events a test hands to every
/// `FakeGhosttyPaneSurface` it creates through `FakeGhosttyPaneFactory`, so
/// it can assert the ORDER two different panes' surfaces were told to
/// switch mode in -- the cross-pane invariant `reconcilePaneModeIfNeeded`
/// owns (old pane's `.observe` before new pane's `.control`).
private final class ModeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [(pane: PaneID, mode: PaneMode)] = []

    func record(pane: PaneID, mode: PaneMode) {
        lock.lock()
        defer { lock.unlock() }
        events.append((pane, mode))
    }
}

/// A fake `GhosttyPaneSurface`: records what `SessionViewModel` does to it,
/// with no real libghostty surface, `NSView`, or bridge process anywhere.
/// `setMode` can be held open one call at a time (mirroring
/// `FakeGhosttyPaneFactory.makeSurface`'s own hold/release), so a test can
/// pin a stale mode-switch mid-flight while a fresher one for the same pane
/// races it. `detach()` has no hold/release of its own:
/// `SessionViewModel.performDetach` removes the pane's `ghosttySurfaces`
/// entry SYNCHRONOUSLY, before ever calling this method, so nothing a held
/// `detach()` here could still be "in the middle of" would leave that
/// dictionary entry in a stale state for another call to race against.
/// `@unchecked Sendable` for the same reason `GhosttySessionSurfaceHandle`
/// is: every touch of this class's state happens through its own
/// `@MainActor`-isolated methods, from tests that are themselves
/// `@MainActor`, even when a value crosses through `Task.value`.
@MainActor
private final class FakeGhosttyPaneSurface: GhosttyPaneSurface, @unchecked Sendable {
    let pane: PaneID
    private(set) var resizeCalls: [(cols: Int, rows: Int)] = []
    private(set) var detachCallCount = 0
    private(set) var parkCallCount = 0
    private(set) var unparkCallCount = 0
    private(set) var modeCalls: [PaneMode] = []
    private(set) var currentMode: PaneMode?
    /// Test-driven, like a real bridge's status FIFO would flip it: starts
    /// `false`, and a test flips it directly to simulate the bridge's
    /// `paddock.first_frame` line landing.
    var hasFirstFrame = false
    var sharedModeLog: ModeEventLog?
    private var holdModeEnabled = false
    private var pendingModeContinuations: [CheckedContinuation<Void, Never>] = []

    init(pane: PaneID) {
        self.pane = pane
    }

    func resize(cols: Int, rows: Int) {
        resizeCalls.append((cols, rows))
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

    func holdMode() {
        holdModeEnabled = true
    }

    func releaseNextMode() {
        guard !pendingModeContinuations.isEmpty else { return }
        pendingModeContinuations.removeFirst().resume()
    }

    func setMode(_ mode: PaneMode) async {
        if holdModeEnabled {
            await withCheckedContinuation { pendingModeContinuations.append($0) }
        }
        modeCalls.append(mode)
        currentMode = mode
        sharedModeLog?.record(pane: pane, mode: mode)
    }
}

/// A fake `GhosttyPaneFactory` for `SessionViewModelTests`' ghostty attach
/// lifecycle tests -- records every `makeSurface` call (including the
/// `onUserInput` closure `SessionViewModel` hands it, so a test can invoke
/// it directly to pin the launcher-pristine contract) and hands back a
/// `FakeGhosttyPaneSurface` per pane. `makeSurface` can be held open one
/// call at a time, the same shape as `RecordingCommandClient.hold`/
/// `releaseNext`, so a test can pin a first attach mid-creation while a
/// resize races it.
@MainActor
private final class FakeGhosttyPaneFactory: GhosttyPaneFactory {
    private(set) var makeSurfaceCalls: [(pane: PaneID, cols: Int, rows: Int)] = []
    private(set) var surfaces: [PaneID: FakeGhosttyPaneSurface] = [:]
    private(set) var onUserInputHandlers: [PaneID: () -> Void] = [:]
    private(set) var onScreenActivityHandlers: [PaneID: (Int) -> Bool] = [:]
    var modeLog: ModeEventLog?
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
        for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        makeSurfaceCalls.append((pane, cols, rows))
        onUserInputHandlers[pane] = onUserInput
        onScreenActivityHandlers[pane] = onScreenActivity
        if holdEnabled {
            await withCheckedContinuation { pendingContinuations.append($0) }
        }
        let surface = FakeGhosttyPaneSurface(pane: pane)
        surface.sharedModeLog = modeLog
        surfaces[pane] = surface
        return surface
    }
}

private func stringParam(_ params: [String: JSONValue], _ key: String) -> String? {
    guard case .string(let value)? = params[key] else { return nil }
    return value
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

    @MainActor
    func testLaunchHarnessSendsBinaryAndNewlineAsOneTextCallAndHidesTheLauncher() async {
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client)
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        XCTAssertTrue(viewModel.isPristineLauncherPane(newPane))

        await viewModel.launchHarness("claude", in: newPane)

        let calls = await client.calls
        let sendCall = try? XCTUnwrap(calls.last { $0.method == "pane.send_input" })
        XCTAssertEqual(stringParam(sendCall?.params ?? [:], "text"), "claude\n")
        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane), "launching hides the overlay like a real keystroke would")
    }

    /// A launcher click can land on a pane that is NOT the resolved-focused
    /// one (split right, click back into the original pane, then click the
    /// overlay on the new pane) -- that pane's bridge is in observe mode,
    /// which drops every byte written straight into its PTY. `launchHarness`
    /// must reach it over `pane.send_input` regardless, never through the
    /// surface itself.
    @MainActor
    func testLaunchHarnessReachesAnObserveModePaneViaSendInputNotThePTY() async throws {
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory)
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        // No focus is ever set on this view model, so the new pane's
        // surface stays in the bridge's default observe mode for the whole
        // test -- never armed to control.
        _ = await viewModel.attachPane(newPane, cols: 80, rows: 24)
        let surface = try XCTUnwrap(factory.surfaces[newPane])
        XCTAssertTrue(viewModel.isPristineLauncherPane(newPane))

        await viewModel.launchHarness("claude", in: newPane)

        let calls = await client.calls
        let sendCall = try XCTUnwrap(calls.last { $0.method == "pane.send_input" })
        XCTAssertEqual(
            stringParam(sendCall.params, "text"), "claude\n",
            "the command reaches the pane over pane.send_input, focus-independent")
        XCTAssertTrue(
            surface.modeCalls.isEmpty,
            "the pane's surface was never armed to control -- send_input, not the PTY, is what delivered this")
        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane))
    }

    // MARK: - ghostty pane attach (every visible pane, one surface for its whole life)

    @MainActor
    func testAttachIsANoOpWithNoFactoryInjected() async {
        let viewModel = SessionViewModel(client: RecordingCommandClient())

        let surface = await viewModel.attachPane(PaneID(rawValue: "w1:p1"), cols: 80, rows: 24)

        XCTAssertNil(surface)
    }

    @MainActor
    func testAttachCreatesExactlyOneSurfacePerPane() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let first = await viewModel.attachPane(pane, cols: 80, rows: 24)
        let second = await viewModel.attachPane(pane, cols: 100, rows: 30)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "a resize must never spawn a second surface for the same pane")
        XCTAssertTrue(first === second, "the same surface instance is handed back across a resize")
    }

    /// Pins the seam contract, not a claim about real ghostty behavior:
    /// `SessionViewModel` forwards a dims change to the existing surface's
    /// `resize(cols:rows:)` unconditionally. Production's own conformance
    /// (`GhosttySessionSurfaceHandle.resize`) deliberately ignores the call --
    /// a real surface's size is pixel-layout-driven, never cols/rows-driven
    /// (see that method's own doc comment) -- so this only proves the
    /// ViewModel-to-surface forwarding, not that resizing does anything
    /// visible in production.
    @MainActor
    func testAttachForwardsResizeCallToTheExistingSurface() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        _ = await viewModel.attachPane(pane, cols: 100, rows: 30)

        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.resizeCalls.map(\.cols), [100])
        XCTAssertEqual(surface.resizeCalls.map(\.rows), [30])
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

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
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

        let first = await viewModel.attachPane(pane, cols: 80, rows: 24)
        await viewModel.detachPane(pane)
        let second = await viewModel.attachPane(pane, cols: 100, rows: 30)

        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "a reattach after a park must never create a second surface")
        XCTAssertTrue(first === second, "the same surface instance comes back")
        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.unparkCallCount, 1, "a warm reattach unparks the surface")
        XCTAssertEqual(surface.resizeCalls.map(\.cols), [100], "the reattach's own dims still resize it")
    }

    /// A pane parked while it was NOT the focused (control-mode) one must
    /// never get a redundant `.observe` send -- the bridge already defaults
    /// to observe, and `attachArmsControlOnlyForTheAlreadyFocusedPane`
    /// already proves an unfocused attach touches mode not at all.
    @MainActor
    func testParkingAnAlreadyObservePaneSendsNoRedundantModeCall() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        await viewModel.detachPane(pane)

        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.modeCalls, [], "the pane was never focused, so parking it must not touch mode at all")
    }

    /// A pane parked while it WAS the focused (control-mode) one is dropped
    /// to observe first.
    @MainActor
    func testParkingAControlModePaneSwitchesItToObserveFirst() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.currentMode, .control)

        await viewModel.detachPane(pane)

        XCTAssertEqual(surface.currentMode, .observe, "a parked pane must be in observe mode")
        XCTAssertEqual(surface.modeCalls, [.control, .observe])
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
            _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
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
            _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        }
        for pane in panes {
            await viewModel.detachPane(pane)
        }
        XCTAssertEqual(factory.makeSurfaceCalls.count, 13)
        let evictedPane = panes[0]
        XCTAssertNil(viewModel.ghosttySurface(for: evictedPane), "the oldest-parked pane was evicted")

        let reattached = await viewModel.attachPane(evictedPane, cols: 80, rows: 24)

        XCTAssertNotNil(reattached)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 14, "the evicted pane's reattach must create a NEW surface, not reuse the torn-down one")
    }

    /// a warm reattach that lands on the resolved-focused pane must arm
    /// control, exactly like a cold attach does (`testAttachArmsControlOnly
    /// ForTheAlreadyFocusedPane`) -- otherwise a pane whose tab is switched
    /// back TO because it holds herdr's focus would sit warm in observe mode
    /// until an unrelated focus flip happened to reconcile it.
    @MainActor
    func testWarmReattachArmsControlWhenThePaneIsResolvedFocused() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        await viewModel.detachPane(pane)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.modeCalls, [], "never focused, so parking it touched mode not at all -- see testParkingAnAlreadyObservePaneSendsNoRedundantModeCall")

        // herdr's focus (and so paddock's resolved focus) is now on this
        // pane -- the tab it belongs to is being switched back to BECAUSE it
        // holds focus, the realistic case this covers.
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)

        XCTAssertEqual(surface.currentMode, .control, "a warm reattach onto the resolved-focused pane must arm control")
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
        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)

        // Neither call is awaited before the next fires -- both `Task { }`
        // closures are simply created back to back, exactly like the two
        // independent SwiftUI-driven call sites do in production.
        let parkTask = Task { await viewModel.detachPane(pane) }
        let attachTask = Task { _ = await viewModel.attachPane(pane, cols: 80, rows: 24) }
        await parkTask.value
        await attachTask.value

        // Whichever of the two settles last, the pane must end up NOT
        // eligible for warm eviction while it is reachable/visible: prove
        // it by parking 12 MORE panes afterward (the full warm cap) and
        // confirming this one is never swept up as if it were still parked.
        let otherPanes = (2...13).map { PaneID(rawValue: "w1:p\($0)") }
        for other in otherPanes {
            _ = await viewModel.attachPane(other, cols: 80, rows: 24)
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

        _ = await viewModel.attachPane(oldPane, cols: 80, rows: 24)
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

        let newSurface = await viewModel.attachPane(newPane, cols: 80, rows: 24)
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

        _ = await viewModel.attachPane(paneA, cols: 80, rows: 24)
        _ = await viewModel.attachPane(paneB, cols: 80, rows: 24)
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

        _ = await viewModel.attachPane(closingPane, cols: 80, rows: 24)
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

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertFalse(surface.hasFirstFrame, "a cold attach starts without a first frame -- the card shows")

        surface.hasFirstFrame = true
        await viewModel.detachPane(pane)
        let reattached = await viewModel.attachPane(pane, cols: 80, rows: 24)

        XCTAssertTrue(reattached === surface)
        XCTAssertEqual(reattached?.hasFirstFrame, true, "a warm reattach's surface already carries its first frame -- the card never comes back")
    }

    /// A resize arriving while the FIRST-EVER attach for a pane is still
    /// awaiting `makeSurface` must not spawn (or leave reachable) a second
    /// surface at the stale, superseded dims.
    @MainActor
    func testResizeDuringInFlightFirstAttachEndsAtNewestDimsWithNoStaleSurfaceLeaked() async throws {
        let factory = FakeGhosttyPaneFactory()
        factory.hold()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let firstTask = Task { await viewModel.attachPane(pane, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let secondTask = Task { await viewModel.attachPane(pane, cols: 100, rows: 30) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        factory.releaseNext()
        let firstSurface = await firstTask.value
        let secondSurface = await secondTask.value

        XCTAssertNotNil(firstSurface, "the first-ever attach for this pane returns the real surface")
        XCTAssertNotNil(secondSurface, "the resize resolves too, once creation settles")
        XCTAssertTrue(firstSurface === secondSurface, "no stale second surface may exist for the same pane")
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "only ONE makeSurface call, even though a resize arrived mid-creation")

        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.resizeCalls.map(\.cols), [100], "the newest dims are applied via resize once creation settles")
        XCTAssertEqual(surface.resizeCalls.map(\.rows), [30])

        // The actual discriminator: without `paneWork` serialization, the
        // resize could race ahead of the held creation and see no surface
        // yet, spawning its OWN second one at the stale dims.
        let noop = await viewModel.attachPane(pane, cols: 100, rows: 30)
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

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
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

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
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

    // MARK: - mode switch (focus-driven, at most one control-mode pane)

    /// A pane attached while it is ALREADY the resolved-focused pane is
    /// armed `.control` immediately, with no separate reconcile round trip
    /// needed; any other pane's attach never touches mode at all (the
    /// bridge's own default, observe, is left alone).
    @MainActor
    func testAttachArmsControlOnlyForTheAlreadyFocusedPane() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        let focused = PaneID(rawValue: "w1:p1")
        let other = PaneID(rawValue: "w1:p2")

        _ = await viewModel.attachPane(focused, cols: 80, rows: 24)
        _ = await viewModel.attachPane(other, cols: 80, rows: 24)

        XCTAssertEqual(factory.surfaces[focused]?.modeCalls, [.control])
        XCTAssertEqual(factory.surfaces[other]?.modeCalls, [], "an unfocused pane's surface is never told to switch mode at attach")
    }

    /// Across a focus flip sequence (A focused, flip to B, flip back to A),
    /// exactly one pane's surface holds `.control` at every settle point,
    /// and BOTH panes keep exactly one surface each -- `attachPane` never
    /// creates a second one, no matter how many times focus moves.
    @MainActor
    func testExactlyOneControlModePaneAcrossAFocusFlipSequence() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        let paneA = PaneID(rawValue: "w1:p1")
        let paneB = PaneID(rawValue: "w1:p2")

        _ = await viewModel.attachPane(paneA, cols: 80, rows: 24)
        _ = await viewModel.attachPane(paneB, cols: 80, rows: 24)
        XCTAssertEqual(factory.surfaces[paneA]?.currentMode, .control)
        XCTAssertNotEqual(factory.surfaces[paneB]?.currentMode, .control)

        viewModel.update(model: makeModel(focusedPaneID: "w1:p2"), connection: .live)
        await viewModel.waitForPaneModeReconciliation()
        XCTAssertEqual(factory.surfaces[paneA]?.currentMode, .observe)
        XCTAssertEqual(factory.surfaces[paneB]?.currentMode, .control)

        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        await viewModel.waitForPaneModeReconciliation()
        XCTAssertEqual(factory.surfaces[paneA]?.currentMode, .control)
        XCTAssertEqual(factory.surfaces[paneB]?.currentMode, .observe)

        XCTAssertEqual(factory.makeSurfaceCalls.count, 2, "exactly one surface per pane across the whole flip sequence")
    }

    /// The cross-pane ordering the mode switch owns: the OLD focused pane's
    /// surface is told `.observe` before the NEW one is told `.control`.
    /// Both panes attach before either is ever focused, so the ONLY mode
    /// events on the shared log are the ones this focus flip itself
    /// produces (the very first focus, A with no prior "old", then the
    /// flip to B) -- isolating the ordering invariant from the separate
    /// attach-time arm behavior `testAttachArmsControlOnlyForTheAlreadyFocusedPane`
    /// already covers.
    @MainActor
    func testFocusFlipSendsObserveToOldPaneBeforeControlToNewPane() async {
        let factory = FakeGhosttyPaneFactory()
        let modeLog = ModeEventLog()
        factory.modeLog = modeLog
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let paneA = PaneID(rawValue: "w1:p1")
        let paneB = PaneID(rawValue: "w1:p2")

        _ = await viewModel.attachPane(paneA, cols: 80, rows: 24)
        _ = await viewModel.attachPane(paneB, cols: 80, rows: 24)
        XCTAssertTrue(modeLog.events.isEmpty, "neither pane is focused yet, so attach must not have armed anything")

        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        await viewModel.waitForPaneModeReconciliation()

        viewModel.update(model: makeModel(focusedPaneID: "w1:p2"), connection: .live)
        await viewModel.waitForPaneModeReconciliation()

        XCTAssertEqual(modeLog.events.map(\.pane), [paneA, paneA, paneB])
        XCTAssertEqual(
            modeLog.events.map(\.mode), [.control, .observe, .control],
            "A arms first (no prior pane to demote); the flip then demotes A before promoting B"
        )
    }

    /// The stale-task race, adapted to modes: a stale mode-switch request
    /// for a pane (its own `setMode` call held open) must not be allowed to
    /// land AFTER a fresher request for the SAME pane and clobber it -- the
    /// pane must settle at whatever the LAST request asked for.
    @MainActor
    func testStaleSupersededModeSwitchCannotClobberAFresherOneOnTheSamePane() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")
        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        let surface = try XCTUnwrap(factory.surfaces[pane])

        surface.holdMode()
        let staleTask = Task { await viewModel.setPaneMode(.observe, for: pane) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let freshTask = Task { await viewModel.setPaneMode(.control, for: pane) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        surface.releaseNextMode()
        _ = await staleTask.value
        surface.releaseNextMode()
        _ = await freshTask.value

        XCTAssertEqual(surface.currentMode, .control, "the settled mode must match the LAST request, never the stale one")
        XCTAssertEqual(surface.modeCalls, [.observe, .control])
    }

    /// The cross-pane race the single-pane stale test above cannot see:
    /// `reconcilePaneModeIfNeeded` fires one `Task` per focus transition, and
    /// each one's own two steps chase DIFFERENT panes (old, then new), so
    /// two overlapping transitions never serialize against each other
    /// directly the way two calls for the SAME pane do. Holding pane A's OWN
    /// `setMode` call open is what forces the race: while the first
    /// transition's (A -> B) own A-step sits parked, the second transition
    /// (B -> A, arriving before the first ever finishes) races its OWN B-step
    /// in ahead unheld, so when the first transition's A-step finally
    /// releases and it moves on to ITS B-step, that step is the one
    /// enqueued LAST on B's chain -- exactly the ordering the review's own
    /// probe used to reproduce A=[control, observe, control],
    /// B=[observe, control] (both panes left in `.control`) from a captured,
    /// not run-time-derived, mode decision.
    @MainActor
    func testHeldABAFlipCannotLeaveTwoControlModePanes() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let paneA = PaneID(rawValue: "w1:p1")
        let paneB = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(paneA, cols: 80, rows: 24)
        _ = await viewModel.attachPane(paneB, cols: 80, rows: 24)
        let surfaceA = try XCTUnwrap(factory.surfaces[paneA])
        let surfaceB = try XCTUnwrap(factory.surfaces[paneB])

        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        await viewModel.waitForPaneModeReconciliation()
        XCTAssertEqual(surfaceA.currentMode, .control)

        // Flip to B, but hold A's own `setMode` call (its demotion to
        // observe) open mid-flight -- this is the FIRST transition's own
        // first step.
        surfaceA.holdMode()
        viewModel.update(model: makeModel(focusedPaneID: "w1:p2"), connection: .live)
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Flip back to A while the first transition's A-step is still
        // parked. This second transition's OWN B-step (unheld) races in and
        // settles B at .observe before the first transition ever reaches
        // its own (stale) B-step.
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        try? await Task.sleep(nanoseconds: 30_000_000)

        surfaceA.releaseNextMode() // releases the first transition's parked A-step (-> observe)
        try? await Task.sleep(nanoseconds: 30_000_000)
        surfaceA.releaseNextMode() // releases the second transition's own A-step (-> control)
        await viewModel.waitForPaneModeReconciliation()

        XCTAssertEqual(surfaceA.currentMode, .control, "the actually-focused pane must end up armed")
        XCTAssertNotEqual(surfaceB.currentMode, .control, "no other pane may still be control-mode once the dust settles")
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

        await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        XCTAssertEqual(executor.executedPlans.map(\.label), ["Move pane into tab"])
        XCTAssertTrue(journal.canUndo)
        XCTAssertEqual(journal.undoLabel, "Move pane into tab")
        XCTAssertTrue(notices.messages.isEmpty)
    }

    @MainActor
    func testPerformRoutesAnInvalidCombinationToTheNoticeSinkWithoutTouchingTheExecutor() async {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .workspaceRail(insertIndex: 0))

        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertFalse(journal.canUndo)
        XCTAssertEqual(notices.messages, ["Can't move there"])
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

        await viewModel.perform(subject: .pane(PaneID(rawValue: "w1:p1")), target: .tabThumbnail(TabID(rawValue: "w1:t2")))

        XCTAssertFalse(journal.canUndo)
        XCTAssertEqual(notices.messages, ["Move pane into tab failed: boom happened"])
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
}
