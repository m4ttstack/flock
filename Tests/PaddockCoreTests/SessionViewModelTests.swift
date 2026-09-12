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

/// Records requests like `RecordingCommandClient` but answers `pane.read`
/// with a canned `text` payload, so backfill tests can assert the fed bytes
/// as well as the request params.
private actor StubReadCommandClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private let readText: String

    init(readText: String = "seeded\n") {
        self.readText = readText
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        guard method == "pane.read" else { return Data("{}".utf8) }
        let escaped = readText.replacingOccurrences(of: "\n", with: "\\n")
        return Data(#"{"result":{"text":"\#(escaped)"}}"#.utf8)
    }
}

/// Answers `pane.read` (backfill), `pane.get` (total row count), and
/// `pane.selection.read` (a deep-history chunk) -- an end-to-end integration
/// double proving `SessionViewModel.performAttach` seeds `PaneTerminal`'s
/// backfill BEFORE any `loadOlderHistory` call can run, so the first chunk
/// never overlaps what backfill already covers.
private actor StubHistoryIntegrationClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private let backfillLineCount: Int
    private let totalRows: Int

    init(backfillLineCount: Int, totalRows: Int) {
        self.backfillLineCount = backfillLineCount
        self.totalRows = totalRows
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        switch method {
        case "pane.read":
            let text = (0..<backfillLineCount).map { "backfill-\($0)" }.joined(separator: "\\n")
            return Data(#"{"result":{"text":"\#(text)"}}"#.utf8)
        case "pane.get":
            let maxOffset = totalRows - 24
            return Data(
                #"{"result":{"pane":{"revision":0,"scroll":{"max_offset_from_bottom":\#(maxOffset),"viewport_rows":24}}}}"#
                    .utf8
            )
        case "pane.selection.read":
            return Data(#"{"result":{"text":"OLDER"}}"#.utf8)
        default:
            return Data("{}".utf8)
        }
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

/// A test double for `ObserveSupervisor` that records calls and hands back
/// a controllable `AsyncStream` per pane, without spawning real processes.
private actor RecordingObserveAttacher: PaneObserveAttaching {
    private(set) var attachCalls: [(pane: PaneID, cols: Int, rows: Int)] = []
    private(set) var reattachCalls: [(pane: PaneID, cols: Int, rows: Int)] = []
    private(set) var detachCalls: [PaneID] = []
    // Mirrors `ObserveSupervisor`'s own real session bookkeeping: a
    // `reattach` on a pane with no session is a documented no-op there
    // (`guard let old = sessions.removeValue(forKey: pane) else { return
    // }`). A fake that unconditionally "succeeds" on every reattach call
    // regardless of whether an attach ever happened would hide an
    // interleaving bug entirely -- the raw call logs above look identical
    // either way; only this settled state tells buggy and fixed apart.
    private(set) var sessionDims: [PaneID: (cols: Int, rows: Int)] = [:]
    private var continuations: [PaneID: AsyncStream<TerminalFrame>.Continuation] = [:]
    private var detachHoldEnabled = false
    private var pendingDetachContinuations: [CheckedContinuation<Void, Never>] = []

    func attach(_ pane: PaneID, cols: Int, rows: Int) async -> AsyncStream<TerminalFrame> {
        attachCalls.append((pane, cols, rows))
        sessionDims[pane] = (cols, rows)
        let (stream, continuation) = AsyncStream<TerminalFrame>.makeStream()
        continuations[pane] = continuation
        return stream
    }

    func reattach(_ pane: PaneID, cols: Int, rows: Int) async {
        reattachCalls.append((pane, cols, rows))
        guard sessionDims[pane] != nil else { return }
        sessionDims[pane] = (cols, rows)
    }

    /// Every subsequent `detach` call suspends until `releaseNextDetach()`
    /// resumes it, one at a time (FIFO) -- lets a test pin a detach mid-
    /// flight while a superseding attach request queues up behind it.
    func holdDetach() { detachHoldEnabled = true }

    func releaseNextDetach() {
        guard !pendingDetachContinuations.isEmpty else { return }
        pendingDetachContinuations.removeFirst().resume()
    }

    func detach(_ pane: PaneID) async {
        detachCalls.append(pane)
        if detachHoldEnabled {
            await withCheckedContinuation { pendingDetachContinuations.append($0) }
        }
        sessionDims.removeValue(forKey: pane)
        continuations.removeValue(forKey: pane)?.finish()
    }
}

/// A fake `GhosttyPaneSurface`: records what `SessionViewModel` does to it,
/// with no real libghostty surface, `NSView`, or bridge process anywhere.
/// `detach()` has no hold/release of its own (unlike
/// `RecordingObserveAttacher`'s): `SessionViewModel.performGhosttyDetach`
/// removes the pane's `ghosttySurfaces` entry SYNCHRONOUSLY, before ever
/// calling this method, so nothing a held `detach()` here could still be
/// "in the middle of" would leave that dictionary entry in a stale state
/// for another call to race against -- see
/// `testGhosttyAttachWaitsForAPendingObserveDetachOnTheSamePaneBeforeCreatingASurface`'s
/// doc comment for the real, structurally-checkable hazard on this seam.
/// `@unchecked Sendable` for the same reason `GhosttySessionSurfaceHandle`
/// is: every touch of this class's state happens through its own
/// `@MainActor`-isolated methods, from tests that are themselves
/// `@MainActor`, even when a value crosses through `Task.value`.
@MainActor
private final class FakeGhosttyPaneSurface: GhosttyPaneSurface, @unchecked Sendable {
    let pane: PaneID
    private(set) var resizeCalls: [(cols: Int, rows: Int)] = []
    private(set) var detachCallCount = 0
    private(set) var typedText: [String] = []

    init(pane: PaneID) {
        self.pane = pane
    }

    func resize(cols: Int, rows: Int) {
        resizeCalls.append((cols, rows))
    }

    func detach() async {
        detachCallCount += 1
    }

    func typeText(_ text: String) {
        typedText.append(text)
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
    private var holdEnabled = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    func hold() {
        holdEnabled = true
    }

    func releaseNext() {
        guard !pendingContinuations.isEmpty else { return }
        pendingContinuations.removeFirst().resume()
    }

    func makeSurface(for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void) async -> any GhosttyPaneSurface {
        makeSurfaceCalls.append((pane, cols, rows))
        onUserInputHandlers[pane] = onUserInput
        if holdEnabled {
            await withCheckedContinuation { pendingContinuations.append($0) }
        }
        let surface = FakeGhosttyPaneSurface(pane: pane)
        surfaces[pane] = surface
        return surface
    }
}

private func makePaneRecord(
    paneID: String = "w1:p1",
    agentStatus: AgentStatus = .unknown,
    viewportRows: Int? = nil
) -> PaneRecord {
    PaneRecord(
        paneID: PaneID(rawValue: paneID), workspaceID: WorkspaceID(rawValue: "w1"),
        tabID: TabID(rawValue: "w1:t1"), focused: false, agentStatus: agentStatus,
        revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp",
        scroll: viewportRows.map { ScrollInfo(offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: $0) }
    )
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

    // MARK: - live attach

    @MainActor
    func testBeginLiveAttachCallsAttacherWithLayoutCellDims() async {
        let attacher = RecordingObserveAttacher()
        let viewModel = SessionViewModel(client: StubReadCommandClient(), observeAttacher: attacher)

        let feed = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)

        XCTAssertNotNil(feed)
        let calls = await attacher.attachCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.pane, PaneID(rawValue: "w1:p1"))
        XCTAssertEqual(calls.first?.cols, 80)
        XCTAssertEqual(calls.first?.rows, 24)
    }

    @MainActor
    func testBeginLiveAttachTwiceWithSameDimsIsANoOp() async {
        let attacher = RecordingObserveAttacher()
        let viewModel = SessionViewModel(client: StubReadCommandClient(), observeAttacher: attacher)

        _ = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)
        let second = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)

        XCTAssertNil(second, "a repeat call with unchanged dims must not re-attach")
        let attachCalls = await attacher.attachCalls
        XCTAssertEqual(attachCalls.count, 1)
    }

    @MainActor
    func testBeginLiveAttachWithChangedDimsReattachesWithoutANewFeed() async {
        let attacher = RecordingObserveAttacher()
        let viewModel = SessionViewModel(client: StubReadCommandClient(), observeAttacher: attacher)

        _ = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)
        let resized = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 100, rows: 30)

        XCTAssertNil(resized, "a dims change reattaches in place; the original stream keeps delivering")
        let reattachCalls = await attacher.reattachCalls
        XCTAssertEqual(reattachCalls.count, 1)
        XCTAssertEqual(reattachCalls.first?.cols, 100)
        XCTAssertEqual(reattachCalls.first?.rows, 30)
        let attachCalls = await attacher.attachCalls
        XCTAssertEqual(attachCalls.count, 1, "reattach must not spawn a second attach")
    }

    @MainActor
    func testEndLiveAttachDetachesAndAllowsReattach() async {
        let attacher = RecordingObserveAttacher()
        let viewModel = SessionViewModel(client: StubReadCommandClient(), observeAttacher: attacher)

        _ = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)
        await viewModel.endLiveAttach(pane: PaneID(rawValue: "w1:p1"))

        let detachCalls = await attacher.detachCalls
        XCTAssertEqual(detachCalls, [PaneID(rawValue: "w1:p1")])

        // Having left the visible set and detached, a later re-entry attaches
        // fresh (a real new feed), not the same-dims no-op path above.
        let feed = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)
        XCTAssertNotNil(feed)
        let attachCalls = await attacher.attachCalls
        XCTAssertEqual(attachCalls.count, 2)
    }

    @MainActor
    func testBackfillRequestsFullThousandLinesForNonAgentPane() async {
        let attacher = RecordingObserveAttacher()
        let client = StubReadCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher)
        let pane = makePaneRecord(agentStatus: .unknown, viewportRows: 24)

        _ = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24)

        let calls = await client.calls
        let readCall = calls.first { $0.method == "pane.read" }
        XCTAssertEqual(readCall.flatMap { intParam($0.params, "lines") }, 1000)
    }

    @MainActor
    func testBackfillCapsLinesToViewportRowsForRecognizedAgentPane() async {
        let attacher = RecordingObserveAttacher()
        let client = StubReadCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher)
        let pane = makePaneRecord(agentStatus: .working, viewportRows: 40)

        _ = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 120, rows: 40)

        let calls = await client.calls
        let readCall = calls.first { $0.method == "pane.read" }
        XCTAssertEqual(readCall.flatMap { intParam($0.params, "lines") }, 40)
    }

    @MainActor
    func testBackfillANSISeedsFromPaneReadText() async {
        let attacher = RecordingObserveAttacher()
        let client = StubReadCommandClient(readText: "backfilled\n")
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher)

        let feed = await viewModel.beginOrUpdateLiveAttach(pane: makePaneRecord(), cols: 80, rows: 24)

        XCTAssertEqual(feed?.backfillANSI.map { String(data: $0, encoding: .utf8) ?? "" }, "backfilled\n")
    }

    // MARK: - live attach reentrancy (fix round 1)

    /// A resize arriving while the FIRST attach for a pane is still
    /// awaiting its backfill RPC must not spawn (or leave running) a
    /// session at the stale, superseded dims -- the pane must end up
    /// attached at the newest requested size, and only that size.
    @MainActor
    func testResizeDuringInFlightFirstAttachEndsAtNewestDimsOnly() async {
        let attacher = RecordingObserveAttacher()
        let client = RecordingCommandClient()
        await client.hold()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher)
        let pane = makePaneRecord()

        let firstTask = Task { await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let secondTask = Task { await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 100, rows: 30) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        await client.releaseNext()
        let firstFeed = await firstTask.value
        let secondFeed = await secondTask.value

        XCTAssertNotNil(firstFeed, "the first-ever attach for this pane returns the real feed")
        XCTAssertNil(secondFeed, "the resize reattaches the same feed in place; no new feed")

        let attachCalls = await attacher.attachCalls
        let reattachCalls = await attacher.reattachCalls
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.cols, 80)
        XCTAssertEqual(reattachCalls.count, 1)
        XCTAssertEqual(reattachCalls.first?.cols, 100)
        XCTAssertEqual(reattachCalls.first?.rows, 30)

        // The actual discriminator: with a naively unserialized attach path,
        // B's `reattach(100,30)` races A's still-in-flight first attach and
        // no-ops (no session exists yet), then A resumes and installs a REAL
        // session at its own stale 80x24 -- so the fake's own settled
        // session state, not just call counts, is what proves the fix.
        let settledSession = await attacher.sessionDims[pane.paneID]
        XCTAssertEqual(settledSession?.cols, 100, "the real observe child must end up at the newest dims")
        XCTAssertEqual(settledSession?.rows, 30)

        // Confirm the settled state really is 100x30, not the stale 80x24:
        // a third call at 100x30 must be a no-op (no session should ever be
        // re-established at 80x24, and the "already attached, same dims"
        // fast path must fire here rather than another reattach).
        let noop = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 100, rows: 30)
        XCTAssertNil(noop)
        let attachCallsAfter = await attacher.attachCalls
        let reattachCallsAfter = await attacher.reattachCalls
        XCTAssertEqual(attachCallsAfter.count, 1, "no session should ever be (re)established at 80x24 again")
        XCTAssertEqual(reattachCallsAfter.count, 1, "settled state is already 100x30; a repeat call is a no-op")
    }

    /// A detach queued (e.g. from `onDisappear`) while it is still in
    /// flight must not be allowed to kill a fresh attach for the same pane
    /// that arrives behind it (a fast reappear) -- the fresh attach must
    /// wait for the stale detach to fully settle, then genuinely re-attach.
    @MainActor
    func testFastReappearAttachIsNotClobberedByAStaleDetach() async {
        let attacher = RecordingObserveAttacher()
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher)
        let pane = makePaneRecord()

        // A real prior attach: the pane was already live.
        let initialFeed = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24)
        XCTAssertNotNil(initialFeed)

        await attacher.holdDetach()
        let detachTask = Task { await viewModel.endLiveAttach(pane: pane.paneID) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Fast reappear: a fresh attach request for the same pane, queued
        // behind the still-in-flight (held) detach.
        let reattachTask = Task { await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        await attacher.releaseNextDetach()
        await detachTask.value
        let feed = await reattachTask.value

        XCTAssertNotNil(feed, "the reappear must re-attach for real, not be silently dropped")
        let attachCalls = await attacher.attachCalls
        XCTAssertEqual(attachCalls.count, 2, "one for the original attach, one for the reappear")
        let detachCalls = await attacher.detachCalls
        XCTAssertEqual(detachCalls, [pane.paneID], "exactly one detach, ordered before the reappear's attach")

        // The actual discriminator: without serialization, the stale
        // detach resumes AFTER the reappear's fresh attach has already
        // installed a new session and wipes it out from under it.
        let settledSession = await attacher.sessionDims[pane.paneID]
        XCTAssertNotNil(settledSession, "the reappear's fresh session must survive the stale queued detach")
        XCTAssertEqual(settledSession?.cols, 80)
        XCTAssertEqual(settledSession?.rows, 24)
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

    // MARK: - ghostty control-plane attach (focused pane)

    @MainActor
    func testGhosttyAttachIsANoOpWithNoFactoryInjected() async {
        let viewModel = SessionViewModel(client: RecordingCommandClient())

        let surface = await viewModel.beginOrUpdateGhosttyAttach(pane: PaneID(rawValue: "w1:p1"), cols: 80, rows: 24)

        XCTAssertNil(surface)
    }

    @MainActor
    func testGhosttyAttachCreatesExactlyOneSurfacePerPane() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let first = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24)
        let second = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 100, rows: 30)

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
    func testGhosttyAttachForwardsResizeCallToTheExistingSurface() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24)
        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 100, rows: 30)

        let surface = try XCTUnwrap(factory.surfaces[pane])
        XCTAssertEqual(surface.resizeCalls.map(\.cols), [100])
        XCTAssertEqual(surface.resizeCalls.map(\.rows), [30])
    }

    @MainActor
    func testEndGhosttyAttachTearsDownTheBridgeChild() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24)
        let surface = try XCTUnwrap(factory.surfaces[pane])
        await viewModel.endGhosttyAttach(pane: pane)

        XCTAssertEqual(surface.detachCallCount, 1)
        XCTAssertNil(viewModel.ghosttySurface(for: pane), "the torn-down surface must not still be reachable")
    }

    @MainActor
    func testGhosttyReattachAfterDetachCreatesAFreshSurface() async {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24)
        await viewModel.endGhosttyAttach(pane: pane)
        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24)

        XCTAssertEqual(factory.makeSurfaceCalls.count, 2, "a fresh attach after a real detach creates a NEW surface")
    }

    /// A resize arriving while the FIRST-EVER ghostty attach for a pane is
    /// still awaiting `makeSurface` must not spawn (or leave reachable) a
    /// second surface at the stale, superseded dims -- mirrors
    /// `testResizeDuringInFlightFirstAttachEndsAtNewestDimsOnly`'s discipline
    /// for the observe path, using `FakeGhosttyPaneFactory`'s own hold/release
    /// instead of the command client's.
    @MainActor
    func testGhosttyResizeDuringInFlightFirstAttachEndsAtNewestDimsWithNoStaleSurfaceLeaked() async throws {
        let factory = FakeGhosttyPaneFactory()
        factory.hold()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        let firstTask = Task { await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let secondTask = Task { await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 100, rows: 30) }
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
        let noop = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 100, rows: 30)
        XCTAssertTrue(noop === surface)
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1, "still only one surface ever created for this pane")
    }

    /// A same-renderer "stale detach vs. fast reappear" race, mirroring
    /// `testFastReappearAttachIsNotClobberedByAStaleDetach`'s observe-path
    /// test exactly, does NOT discriminate anything on the ghostty side:
    /// `performGhosttyDetach` removes the pane's `ghosttySurfaces` entry
    /// SYNCHRONOUSLY, as its very first action, before it ever calls
    /// `surface.detach()` -- so by the time any hold on `detach()` could
    /// matter, the dictionary is already cleared, and a reappear sees a
    /// fresh, empty slot whether or not `paneWork` serializes anything.
    /// (The observe path's own version of this test discriminates for real
    /// because ITS fake, `RecordingObserveAttacher`, deliberately defers
    /// clearing its own `sessionDims` entry until AFTER its held `detach`
    /// resumes -- there is no equivalent deferred, fake-owned state here to
    /// race against.)
    ///
    /// The hazard `paneWork` DOES guard on this seam is a RENDERER FLIP: a
    /// pane transitioning from observe to ghostty (or back) must have the
    /// OLD renderer's detach fully settle before the NEW renderer's attach
    /// is allowed to create anything, because both operations share the
    /// same `paneWork[pane]` chain precisely so they can never run
    /// concurrently for one pane. This is the real, structurally-checkable
    /// property: hold the observe detach, start a ghostty attach for the
    /// SAME pane behind it, and prove no surface exists until the detach
    /// releases.
    @MainActor
    func testGhosttyAttachWaitsForAPendingObserveDetachOnTheSamePaneBeforeCreatingASurface() async throws {
        let attacher = RecordingObserveAttacher()
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: StubReadCommandClient(), observeAttacher: attacher, ghosttyFactory: factory)
        let pane = makePaneRecord()

        _ = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24)

        await attacher.holdDetach()
        let detachTask = Task { await viewModel.endLiveAttach(pane: pane.paneID) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // The renderer flip: a ghostty attach for the SAME pane, dispatched
        // as its own task, must queue behind the still-in-flight observe
        // detach -- sharing `paneWork` across both renderers is what makes
        // this true; separate per-renderer chains would let it run
        // concurrently instead.
        let ghosttyTask = Task { await viewModel.beginOrUpdateGhosttyAttach(pane: pane.paneID, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(
            factory.makeSurfaceCalls.count, 0,
            "the ghostty attach must not create a surface while the observe detach for the SAME pane is still settling"
        )

        await attacher.releaseNextDetach()
        await detachTask.value
        let surface = await ghosttyTask.value

        XCTAssertNotNil(surface, "the ghostty attach resolves once the observe detach has fully settled")
        XCTAssertEqual(factory.makeSurfaceCalls.count, 1)
    }

    /// The launcher-pristine contract's ghostty half: a keystroke reported
    /// through the ghostty input seam (`onUserInput`, the closure
    /// `GhosttyPaneFactory.makeSurface` is handed) must hide the launcher
    /// exactly like a SwiftTerm pane's `recordLauncherKeystroke` call
    /// already does -- pinned here at the seam `SessionViewModel` actually
    /// owns, with no real `NSEvent`/`GhosttySurfaceView` needed: a ghostty
    /// pane's keys bypass `PaneCellView.routeKeyPress` (and so
    /// `recordLauncherKeystroke`) entirely, so without this wiring a fresh
    /// split's launcher buttons would stay hit-testable over live terminal
    /// output forever.
    @MainActor
    func testGhosttyPaneKeystrokeThroughInputSeamHidesTheLauncher() async throws {
        let factory = FakeGhosttyPaneFactory()
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p2")

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane), "a freshly paddock-created pane starts pristine")

        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane, cols: 80, rows: 24)
        let onUserInput = try XCTUnwrap(factory.onUserInputHandlers[pane])

        onUserInput()

        XCTAssertFalse(
            viewModel.isPristineLauncherPane(pane),
            "a keystroke reported through the ghostty seam must hide the launcher, same as a real one does on SwiftTerm"
        )
    }

    // MARK: - unfocused-pane read-only guarantees (renderer swap)

    /// The structural half of "unfocused panes have no input path": an
    /// observe-attached pane must never carry a ghostty surface, and the
    /// ghostty factory's `onUserInput` handler -- the seam a keystroke
    /// reaches to hide the launcher -- must never be wired for it, since
    /// `makeSurface` (the only place that handler is created) is called
    /// exclusively from `beginOrUpdateGhosttyAttach`.
    @MainActor
    func testObserveAttachedPaneHasNoGhosttySurfaceAndNoInputHandler() async {
        let attacher = RecordingObserveAttacher()
        let factory = FakeGhosttyPaneFactory()
        let client = StubReadCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher, ghosttyFactory: factory)
        let observePane = makePaneRecord(paneID: "w1:p1")
        let ghosttyPane = PaneID(rawValue: "w1:p2")

        _ = await viewModel.beginOrUpdateLiveAttach(pane: observePane, cols: 80, rows: 24)
        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: ghosttyPane, cols: 80, rows: 24)

        XCTAssertNil(
            viewModel.ghosttySurface(for: observePane.paneID),
            "an observe-fed pane must never carry a ghostty surface"
        )
        XCTAssertNil(
            factory.onUserInputHandlers[observePane.paneID],
            "no ghostty input handler was ever wired for the observe-fed pane"
        )
        XCTAssertEqual(
            factory.makeSurfaceCalls.map(\.pane), [ghosttyPane],
            "makeSurface must only ever be called for a pane that went through the ghostty attach path"
        )
    }

    /// Across a focus flip sequence (A armed, flip to B, flip back to A),
    /// exactly one pane carries a live ghostty surface at every settle point
    /// and the other is confirmed observe-fed via the fake's own session
    /// state -- not just call counts, which would stay identical whether the
    /// invariant held or not.
    @MainActor
    func testExactlyOneArmedPaneAcrossAFocusFlipSequence() async {
        let attacher = RecordingObserveAttacher()
        let factory = FakeGhosttyPaneFactory()
        let client = StubReadCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher, ghosttyFactory: factory)
        let paneA = makePaneRecord(paneID: "w1:p1")
        let paneB = makePaneRecord(paneID: "w1:p2")

        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: paneA.paneID, cols: 80, rows: 24)
        _ = await viewModel.beginOrUpdateLiveAttach(pane: paneB, cols: 80, rows: 24)
        await assertExactlyOneArmedPane(armed: paneA.paneID, observed: paneB.paneID, viewModel: viewModel, attacher: attacher)

        // Flip to B: each pane attaches its NEW transport before tearing
        // down its OLD one, matching `PaneCellView`'s own per-pane ordering.
        _ = await viewModel.beginOrUpdateLiveAttach(pane: paneA, cols: 80, rows: 24)
        await viewModel.endGhosttyAttach(pane: paneA.paneID)
        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: paneB.paneID, cols: 80, rows: 24)
        await viewModel.endLiveAttach(pane: paneB.paneID)
        await assertExactlyOneArmedPane(armed: paneB.paneID, observed: paneA.paneID, viewModel: viewModel, attacher: attacher)

        // Flip back to A.
        _ = await viewModel.beginOrUpdateLiveAttach(pane: paneB, cols: 80, rows: 24)
        await viewModel.endGhosttyAttach(pane: paneB.paneID)
        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: paneA.paneID, cols: 80, rows: 24)
        await viewModel.endLiveAttach(pane: paneA.paneID)
        await assertExactlyOneArmedPane(armed: paneA.paneID, observed: paneB.paneID, viewModel: viewModel, attacher: attacher)
    }

    @MainActor
    private func assertExactlyOneArmedPane(
        armed: PaneID, observed: PaneID, viewModel: SessionViewModel, attacher: RecordingObserveAttacher,
        line: UInt = #line
    ) async {
        XCTAssertNotNil(viewModel.ghosttySurface(for: armed), "\(armed.rawValue) must be the one armed pane", line: line)
        XCTAssertNil(viewModel.ghosttySurface(for: observed), "\(observed.rawValue) must not carry a ghostty surface", line: line)
        let sessionDims = await attacher.sessionDims
        XCTAssertNotNil(sessionDims[observed], "the non-armed pane must be observe-fed", line: line)
        XCTAssertNil(sessionDims[armed], "the armed pane must not still carry an observe session", line: line)
    }

    /// Pane losing focus (ghostty -> swiftTerm): `PaneCellView` attaches the
    /// new observe transport BEFORE tearing down the old ghostty surface.
    /// Discriminator: while the observe attach's backfill RPC is still held
    /// open, the ghostty surface must still be armed -- a detach-old-first
    /// ordering would have already torn it down before this attach was even
    /// issued, leaving the pane transiently fed by neither transport.
    @MainActor
    func testFocusLossKeepsGhosttyArmedUntilTheObserveAttachIsLive() async {
        let attacher = RecordingObserveAttacher()
        let factory = FakeGhosttyPaneFactory()
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher, ghosttyFactory: factory)
        let pane = makePaneRecord()

        _ = await viewModel.beginOrUpdateGhosttyAttach(pane: pane.paneID, cols: 80, rows: 24)
        XCTAssertNotNil(viewModel.ghosttySurface(for: pane.paneID))

        await client.hold()
        let attachTask = Task { await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNotNil(
            viewModel.ghosttySurface(for: pane.paneID),
            "the pane must never sit with no live transport while the new (observe) attach is still settling"
        )

        await client.releaseNext()
        let feed = await attachTask.value
        XCTAssertNotNil(feed)

        await viewModel.endGhosttyAttach(pane: pane.paneID)
        XCTAssertNil(viewModel.ghosttySurface(for: pane.paneID))
        let attachCalls = await attacher.attachCalls
        XCTAssertEqual(attachCalls.count, 1)
    }

    /// Symmetric case: pane gaining focus (swiftTerm -> ghostty). While the
    /// ghostty surface is still being created, the observe attach must not
    /// yet have been torn down -- a detach-old-first ordering would already
    /// have called `detach` here.
    @MainActor
    func testFocusGainKeepsObserveArmedUntilTheGhosttyAttachIsLive() async {
        let attacher = RecordingObserveAttacher()
        let factory = FakeGhosttyPaneFactory()
        factory.hold()
        let client = StubReadCommandClient()
        let viewModel = SessionViewModel(client: client, observeAttacher: attacher, ghosttyFactory: factory)
        let pane = makePaneRecord()

        _ = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24)
        let attachCallsBefore = await attacher.attachCalls
        XCTAssertEqual(attachCallsBefore.count, 1)

        let ghosttyTask = Task { await viewModel.beginOrUpdateGhosttyAttach(pane: pane.paneID, cols: 80, rows: 24) }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let detachCallsDuring = await attacher.detachCalls
        XCTAssertTrue(
            detachCallsDuring.isEmpty,
            "the observe transport must still be feeding while the new (ghostty) attach is still settling"
        )

        factory.releaseNext()
        let surface = await ghosttyTask.value
        XCTAssertNotNil(surface)

        await viewModel.endLiveAttach(pane: pane.paneID)
        let detachCallsAfter = await attacher.detachCalls
        XCTAssertEqual(detachCallsAfter, [pane.paneID])
    }

    // MARK: - deep-history/backfill seeding order

    /// Reported live: the dimmed history region duplicated exactly what the
    /// live buffer already showed. Root cause: the history region is a
    /// VStack sibling declared ABOVE the terminal representable, so its own
    /// `onAppear` (triggering `loadOlderHistory`) could fire before
    /// `TerminalRepresentable.makeNSView` ever ran -- the one place that
    /// used to seed `PaneTerminal`'s backfill -- reading `backfillLineCount`
    /// as its `0` default and anchoring the first chunk at the pane's total
    /// row count, squarely inside what backfill was about to cover.
    /// `performAttach` now seeds backfill itself, before any view can race
    /// it; this proves the first chunk it requests never overlaps.
    @MainActor
    func testFirstHistoryChunkAfterAttachNeverOverlapsSeededBackfill() async throws {
        let client = StubHistoryIntegrationClient(backfillLineCount: 1000, totalRows: 1500)
        let viewModel = SessionViewModel(client: client, observeAttacher: RecordingObserveAttacher())
        let pane = makePaneRecord()

        _ = await viewModel.beginOrUpdateLiveAttach(pane: pane, cols: 80, rows: 24)
        let terminal = viewModel.paneTerminal(for: pane, cols: 80, rows: 24)
        let oldestHeldAbsoluteRow = 1500 - terminal.locallyHeldRowCount()
        _ = try await terminal.loadOlderHistory(chunkRows: 200)

        let calls = await client.calls
        let request = try XCTUnwrap(calls.last { $0.method == "pane.selection.read" })
        guard case .object(let cursor)? = request.params["cursor"] else {
            return XCTFail("expected a cursor param")
        }
        XCTAssertEqual(
            intParam(cursor, "row"), oldestHeldAbsoluteRow - 1,
            "must end exactly where the locally retained buffer begins, never inside it"
        )
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
}

private func intParam(_ params: [String: JSONValue], _ key: String) -> Int? {
    guard case .int(let value)? = params[key] else { return nil }
    return value
}
