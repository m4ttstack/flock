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
    private(set) var modeCalls: [PaneMode] = []
    private(set) var currentMode: PaneMode?
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

        // An unrelated layout_updated leaves focus untouched; the selection
        // (already derived from that focus) must not be reset or cleared.
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
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))
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

    @MainActor
    func testDetachTearsDownTheBridgeChild() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        await viewModel.detachPane(pane)

        XCTAssertEqual(surface.detachCallCount, 1)
        XCTAssertNil(viewModel.ghosttySurface(for: pane), "the torn-down surface must not still be reachable")
    }

    @MainActor
    func testReattachAfterDetachCreatesAFreshSurface() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
        await viewModel.detachPane(pane)
        _ = await viewModel.attachPane(pane, cols: 80, rows: 24)

        XCTAssertEqual(factory.makeSurfaceCalls.count, 2, "a fresh attach after a real detach creates a NEW surface")
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

    /// Local state flips optimistically (matching `jumpToHerdr(pane:)`'s own
    /// pattern) so the checkmark reflects intent on the same frame as the
    /// click; the wire value flips between herdr's two `PaneRightClickTarget`
    /// variants on each toggle.
    @MainActor
    func testToggleRightClickRoutingFlipsStateAndSendsPaneInputSet() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)
        let pane = PaneID(rawValue: "w1:p1")
        XCTAssertFalse(viewModel.isRightClickRoutedToPane(pane), "defaults to herdr, matching the server default")

        await viewModel.toggleRightClickRouting(for: pane)
        XCTAssertTrue(viewModel.isRightClickRoutedToPane(pane))

        await viewModel.toggleRightClickRouting(for: pane)
        XCTAssertFalse(viewModel.isRightClickRoutedToPane(pane))

        let calls = await client.calls
        let setCalls = calls.filter { $0.method == "pane.input.set" }
        XCTAssertEqual(setCalls.count, 2)
        XCTAssertEqual(stringParam(setCalls[0].params, "pane_id"), "w1:p1")
        XCTAssertEqual(stringParam(setCalls[0].params, "right_click"), "pane")
        XCTAssertEqual(stringParam(setCalls[1].params, "right_click"), "herdr")
    }

    @MainActor
    func testToggleRightClickRoutingRevertsLocalStateWhenTheRequestFails() async {
        let viewModel = SessionViewModel(client: FailingCommandClient())
        let pane = PaneID(rawValue: "w1:p1")

        await viewModel.toggleRightClickRouting(for: pane)

        XCTAssertFalse(viewModel.isRightClickRoutedToPane(pane), "a failed round trip must not leave a stale optimistic flip")
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
