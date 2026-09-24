import XCTest
@testable import FlockCore

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

/// Answers every call with herdr's own error envelope shape, so a caller that
/// surfaces failures is checked against the message a real rejection carries
/// rather than a Swift type's description.
private actor ServerErrorCommandClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        throw HerdrClientError.server(code: "workspace_not_found", message: "no such workspace")
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

/// Answers `pane.split` like `StubSplitCommandClient` and `pane.process_info`
/// from a script, one answer per poll, the last one repeating. The busy and
/// idle bodies are herdr 0.9's own `PaneProcessInfo` shape.
private actor StubForegroundClient: HerdrCommandClient {
    enum Answer { case busy, idle, failure }
    struct Failure: Error {}

    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private var script: [Answer]

    init(_ script: [Answer]) {
        self.script = script
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        switch method {
        case "pane.split":
            return Data(#"{"result":{"pane":{"pane_id":"w1:p2"}}}"#.utf8)
        case "pane.process_info":
            let answer = script.count > 1 ? script.removeFirst() : script[0]
            switch answer {
            case .busy:
                return Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":731,"foreground_processes":[{"name":"fzf","pid":731}]},"type":"pane_process_info"}}"#.utf8)
            case .idle:
                return Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"zsh","pid":500}]},"type":"pane_process_info"}}"#.utf8)
            case .failure:
                throw Failure()
            }
        default:
            return Data("{}".utf8)
        }
    }
}

/// Answers `tab.create` and `workspace.create` with herdr's own response
/// shapes (`ResponseResult::TabCreated` and `WorkspaceCreated`, both of which
/// carry the created tab and its root pane), so what a create lands on is
/// read out of the JSON a real herdr sends rather than a shape invented here.
private actor StubCreateCommandClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private let workspaceID: String
    private let tabID: String
    private let paneID: String

    init(workspaceID: String = "w1", tabID: String = "w1:t2", paneID: String = "w1:p2") {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        let tab = #"{"tab_id":"\#(tabID)","workspace_id":"\#(workspaceID)","number":2,"label":"zsh","focused":true,"pane_count":1,"agent_status":"unknown"}"#
        let rootPane = #"{"pane_id":"\#(paneID)","workspace_id":"\#(workspaceID)","tab_id":"\#(tabID)","terminal_id":"t_2","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}"#
        switch method {
        case "tab.create":
            return Data(#"{"result":{"type":"tab_created","tab":\#(tab),"root_pane":\#(rootPane)}}"#.utf8)
        case "workspace.create":
            let workspace = #"{"workspace_id":"\#(workspaceID)","label":"new","number":2,"active_tab_id":"\#(tabID)","agent_status":"unknown"}"#
            return Data(#"{"result":{"type":"workspace_created","workspace":\#(workspace),"tab":\#(tab),"root_pane":\#(rootPane)}}"#.utf8)
        default:
            return Data("{}".utf8)
        }
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

/// A hand-wound clock for the `now` closure `SessionViewModel` takes, so a
/// test can place a report inside or outside a window without sleeping.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
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
    /// Every hold command this surface was sent, in order, so a test can
    /// assert both that a pane was handed back and that it was taken again.
    private(set) var holdCalls: [HoldCommand] = []
    /// Test-driven, like a real bridge's status FIFO would flip it: starts
    /// `false`, and a test flips it directly to simulate the bridge's
    /// `flock.first_frame` line landing.
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

    func releaseHerdrHold() {
        holdCalls.append(.release)
    }

    func takeHerdrHold() {
        holdCalls.append(.take)
    }

    private(set) var resumeScreenActivityCallCount = 0

    func resumeScreenActivityReporting() {
        resumeScreenActivityCallCount += 1
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
    private(set) var onClearRequestedHandlers: [PaneID: () -> Void] = [:]
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
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        makeSurfaceCalls.append(pane)
        onUserInputHandlers[pane] = onUserInput
        onClearRequestedHandlers[pane] = onClearRequested
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

/// Records which panes' agent-status feeds `SessionViewModel` arms and
/// disarms.
@MainActor
private final class FakePaneAgentStatusSubscriber: PaneAgentStatusSubscribing {
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

/// Two tabs of `w1`: `w1:t1` holds `w1:p1` and `w1:p2`, `w1:t2` holds
/// `w1:p3`. What a target naming a pane has to be weighed against to say
/// whether the drop crosses a tab boundary.
private func makeModelWithAPaneInASecondTab() -> SessionModel {
    var model = makeModel()
    model.tabs[WorkspaceID(rawValue: "w1")]?.append(TabRecord(
        tabID: TabID(rawValue: "w1:t2"), workspaceID: WorkspaceID(rawValue: "w1"),
        label: "second", number: 2, paneCount: 1, agentStatus: .unknown
    ))
    for (pane, tab) in [("w1:p2", "w1:t1"), ("w1:p3", "w1:t2")] {
        model.panes[PaneID(rawValue: pane)] = PaneRecord(
            paneID: PaneID(rawValue: pane), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: tab),
            focused: false, agentStatus: .unknown, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp"
        )
    }
    return model
}

private func stringParam(_ params: [String: JSONValue], _ key: String) -> String? {
    guard case .string(let value)? = params[key] else { return nil }
    return value
}

private func boolParam(_ params: [String: JSONValue], _ key: String) -> Bool? {
    guard case .bool(let value)? = params[key] else { return nil }
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

/// `w1` (the one visible workspace, `w1:p1` in `w1:t1`) plus `wF`, a flock
/// owned workspace whose tab `wF:t1` holds `wF:p1`.
private func makeModelWithFlockWorkspace(
    focusedWorkspaceID: String = "w1", focusedTabID: String = "w1:t1", focusedPaneID: String = "w1:p1",
    includingFlockPane: Bool = true
) -> SessionModel {
    let flockPane = includingFlockPane
        ? #",{"pane_id":"wF:p1","terminal_id":"term_f1","workspace_id":"wF","tab_id":"wF:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"}"#
        : ""
    let json = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(focusedWorkspaceID)","focused_tab_id":"\#(focusedTabID)","focused_pane_id":"\#(focusedPaneID)",
     "workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},
                   {"workspace_id":"wF","label":"flock:rt","number":2,"active_tab_id":"wF:t1","agent_status":"unknown"}],
     "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"orig","number":1,"pane_count":1,"agent_status":"unknown"},
             {"tab_id":"wF:t1","workspace_id":"wF","label":"nav term_a1 tok1","number":1,"pane_count":1,"agent_status":"unknown"}],
     "panes":[{"pane_id":"w1:p1","terminal_id":"term_a1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"}\#(flockPane)],
     "layouts":[]}
    """#
    return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
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
        // -- flock's selection only ever follows herdr's focus on a
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

    /// The ruling this task's live tab-switch check depends on: flock's
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
            "herdr's focused tab changed, so flock's selection follows it")
    }

    private static func twoWorkspaceModel(focusedWorkspace: String = "w1", focusedTab: String = "w1:t1") -> SessionModel {
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(focusedWorkspace)","focused_tab_id":"\#(focusedTab)","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"one","number":1,"active_tab_id":"w1:t1","agent_status":"idle"},{"workspace_id":"w2","label":"two","number":2,"active_tab_id":"w2:t1","agent_status":"idle"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"a","number":1,"pane_count":1,"agent_status":"idle"},{"tab_id":"w2:t1","workspace_id":"w2","label":"b","number":1,"pane_count":1,"agent_status":"idle"},{"tab_id":"w2:t2","workspace_id":"w2","label":"c","number":2,"pane_count":1,"agent_status":"idle"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/tmp"}],"layouts":[]}
        """#
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    /// `twoWorkspaceModel` plus a second pane living in `w2:t1`, focus
    /// nowhere near it -- what `focusFromChat` needs to prove it derives the
    /// workspace and tab from the pane's OWN record rather than from
    /// whatever is already selected.
    private static func twoWorkspaceModelWithASecondPane() -> SessionModel {
        var model = twoWorkspaceModel()
        model.panes[PaneID(rawValue: "w2:p5")] = PaneRecord(
            paneID: PaneID(rawValue: "w2:p5"), workspaceID: WorkspaceID(rawValue: "w2"), tabID: TabID(rawValue: "w2:t1"),
            focused: false, agentStatus: .unknown, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp"
        )
        return model
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

    /// After a pane is dropped on another workspace's thumbnail, following it
    /// moves herdr's focus into that workspace. The rail and the strip must
    /// follow along with the canvas, or the window shows two workspaces.
    @MainActor
    func testFollowingHerdrFocusIntoAnotherWorkspacesTabSelectsThatWorkspaceToo() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))

        viewModel.update(model: Self.twoWorkspaceModel(focusedWorkspace: "w2", focusedTab: "w2:t2"), connection: .live)

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w2:t2"))
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(viewModel.tabsForSelectedWorkspace.map(\.tabID), [TabID(rawValue: "w2:t1"), TabID(rawValue: "w2:t2")])
    }

    /// herdr's `tab.close` sends no `tab.focused` after itself, so nothing
    /// else moves flock off a tab that has just gone: the strip and the canvas
    /// would sit on a dead id, showing empty space, until the resnapshot.
    @MainActor
    func testTheSelectionLeavesAClosedTabForItsNeighbor() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)
        viewModel.select(tab: TabID(rawValue: "w2:t2"))

        var closed = Self.twoWorkspaceModel()
        closed.tabs[WorkspaceID(rawValue: "w2")]?.removeAll { $0.tabID == TabID(rawValue: "w2:t2") }
        viewModel.update(model: closed, connection: .live)

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w2:t1"))
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
    }

    /// A tab that was its workspace's last takes the workspace with it, so the
    /// rail has to move too, and onto the surviving row's own active tab.
    @MainActor
    func testTheSelectionLeavesAClosedWorkspaceForASurvivingRow() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)
        viewModel.select(tab: TabID(rawValue: "w2:t2"))

        var closed = Self.twoWorkspaceModel()
        closed.workspaces.removeAll { $0.workspaceID == WorkspaceID(rawValue: "w2") }
        closed.tabs[WorkspaceID(rawValue: "w2")] = nil
        viewModel.update(model: closed, connection: .live)

        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))
    }

    /// A dropped connection is a gap, not a close. Landing the selection
    /// somewhere else on every reconnect would move the user's window while
    /// nothing at all had happened to their session.
    @MainActor
    func testALostConnectionDoesNotMoveTheSelection() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())
        viewModel.update(model: Self.twoWorkspaceModel(), connection: .live)
        viewModel.select(tab: TabID(rawValue: "w2:t2"))

        viewModel.update(model: nil, connection: .reconnecting(attempt: 1))

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w2:t2"))
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
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

    /// Peek's jump verb answers with a bare pane id; the workspace and tab it
    /// focuses come from this pane's own record in the model, not from
    /// anything the verb carries. No `workspace.focus`: `tab.focus` moves
    /// herdr's workspace itself, and a separate one flashes the workspace's
    /// remembered tab first.
    @MainActor
    func testFocusFromChatFocusesTheOwningTabAndPaneFromTheModelAlone() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: Self.twoWorkspaceModelWithASecondPane(), connection: .live)

        await viewModel.focusFromChat(pane: PaneID(rawValue: "w2:p5"))

        let calls = await client.calls
        XCTAssertEqual(calls.map(\.method), ["tab.focus", "pane.focus"])
        XCTAssertEqual(stringParam(calls[0].params, "tab_id"), "w2:t1")
        XCTAssertEqual(stringParam(calls[1].params, "pane_id"), "w2:p5")
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w2:t1"))
    }

    /// A pane the model no longer carries (closed since the verb answered)
    /// has nowhere to focus: nothing is sent, rather than a workspace/tab
    /// jump firing with no pane to land on.
    @MainActor
    func testFocusFromChatForAPaneNoLongerInTheModelSendsNothing() async {
        let client = RecordingCommandClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.focusFromChat(pane: PaneID(rawValue: "gone"))

        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
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

    /// `recordLauncherKeystroke` runs from `GhosttySurfaceView.keyDown`, so it
    /// sits on the key path: once per keystroke, per pane, for as long as the
    /// pane is typed into. `launcherRegistryVersion` is the observation seam
    /// every pane cell's body depends on through `isPristineLauncherPane`, so
    /// bumping it when the answer did not change re-renders every visible pane
    /// on every keystroke for nothing.
    @MainActor
    func testRepeatedKeystrokesInAPaneInvalidateNothingAfterTheFirst() async {
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client)
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        XCTAssertTrue(viewModel.isPristineLauncherPane(newPane))

        viewModel.recordLauncherKeystroke(newPane)
        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane), "the first keystroke hides the launcher")
        let settled = viewModel.launcherRegistryVersion
        for _ in 0..<200 {
            viewModel.recordLauncherKeystroke(newPane)
        }
        XCTAssertEqual(viewModel.launcherRegistryVersion, settled, "typing on past the first keystroke changed nothing")

        // A pane flock never created is never pristine, so every keystroke in
        // it -- which is most of them, most panes coming from herdr -- must
        // invalidate nothing at all.
        let herdrPane = PaneID(rawValue: "w1:p1")
        let before = viewModel.launcherRegistryVersion
        for _ in 0..<200 {
            viewModel.recordLauncherKeystroke(herdrPane)
        }
        XCTAssertEqual(viewModel.launcherRegistryVersion, before)
    }

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
            "the SOURCE pane was never flock-created; only the new one is registered"
        )
    }

    /// A split carries `focus: true` like every other create, so the ring and
    /// the input sink move to the new pane on herdr's answer rather than on
    /// its focus echo.
    @MainActor
    func testSplittingLandsInTheNewPane() async {
        let viewModel = SessionViewModel(client: StubSplitCommandClient(newPaneID: "w1:p2"))
        viewModel.update(model: makeModel(focusedPaneID: "w1:p1"), connection: .live)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p1"))

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))

        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p2"))
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
        // The click back into the original pane: the split itself left the
        // new pane focused, and this takes the focus off it again.
        await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p1"))
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

    // MARK: - a navigator command (rt cd) launched from the launcher

    @MainActor
    func testLaunchNavigatorFocusesThePaneBeforeSubmittingTheCommand() async throws {
        let client = StubForegroundClient([.busy])
        let viewModel = SessionViewModel(client: client, navigationPollInterval: .milliseconds(1))
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        await viewModel.jumpToHerdr(pane: PaneID(rawValue: "w1:p1"))

        await viewModel.launchNavigator("rt cd", in: newPane)

        let calls = await client.calls
        let focusIndex = try XCTUnwrap(calls.lastIndex { $0.method == "pane.focus" })
        let sendIndex = try XCTUnwrap(calls.lastIndex { $0.method == "pane.send_input" })
        XCTAssertEqual(stringParam(calls[focusIndex].params, "pane_id"), "w1:p2")
        XCTAssertLessThan(focusIndex, sendIndex, "the picker takes keys the moment it opens")
        XCTAssertEqual(stringParam(calls[sendIndex].params, "text"), "rt cd")
        XCTAssertEqual(stringArrayParam(calls[sendIndex].params, "keys"), ["Enter"])
        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane), "the launcher steps aside for the picker")
        viewModel.navigationWatches[newPane]?.cancel()
    }

    /// The button stays on screen until the view model says otherwise, so a
    /// second click can land while the first is still focusing and sending.
    @MainActor
    func testASecondClickWhileTheFirstIsStillSendingTypesNothing() async throws {
        let client = StubForegroundClient([.busy])
        let viewModel = SessionViewModel(client: client, navigationPollInterval: .milliseconds(1))
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")

        async let first: Void = viewModel.launchNavigator("rt cd", in: newPane)
        async let second: Void = viewModel.launchNavigator("rt cd", in: newPane)
        _ = await (first, second)

        let sends = await client.calls.filter { $0.method == "pane.send_input" }
        XCTAssertEqual(sends.count, 1)
        viewModel.navigationWatches[newPane]?.cancel()
    }

    @MainActor
    func testTheLauncherComesBackWhenTheNavigatorCloses() async throws {
        let client = StubForegroundClient([.busy, .busy, .idle])
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(
            client: client, ghosttyFactory: factory, navigationPollInterval: .milliseconds(1)
        )
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(newPane)

        await viewModel.launchNavigator("rt cd", in: newPane)
        let watch = try XCTUnwrap(viewModel.navigationWatches[newPane])
        await watch.value

        XCTAssertTrue(viewModel.isPristineLauncherPane(newPane))
        XCTAssertEqual(
            factory.surfaces[newPane]?.resumeScreenActivityCallCount, 1,
            "row counting was off while the picker ran, and the new prompt has to be measured"
        )
        let polls = await client.calls.filter { $0.method == "pane.process_info" }
        XCTAssertEqual(polls.count, 3, "polling stops once the pane is back at its prompt")
        XCTAssertEqual(stringParam(polls[0].params, "pane_id"), "w1:p2")
        XCTAssertNil(viewModel.navigationWatches[newPane])
    }

    @MainActor
    func testANavigatorHerdrStopsAnsweringForLeavesTheLauncherHidden() async throws {
        let client = StubForegroundClient([.busy, .failure])
        let viewModel = SessionViewModel(client: client, navigationPollInterval: .milliseconds(1))
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        let newPane = PaneID(rawValue: "w1:p2")

        await viewModel.launchNavigator("rt cd", in: newPane)
        let watch = try XCTUnwrap(viewModel.navigationWatches[newPane])
        await watch.value

        XCTAssertFalse(viewModel.isPristineLauncherPane(newPane))
        XCTAssertNil(viewModel.navigationWatches[newPane])
        let polls = await client.calls.filter { $0.method == "pane.process_info" }
        XCTAssertEqual(polls.count, 2)
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

    // MARK: - per-pane agent status feed (armed for every pane in the model)

    /// Scoped to the model, not to what is on screen: a pane in an unselected
    /// tab of an unselected workspace is exactly the pane the rail dot and
    /// the attention toasts exist to report, and it is never attached.
    @MainActor
    func testEveryPaneInTheModelGetsAnAgentStatusFeedIncludingUnseenOnes() {
        let status = FakePaneAgentStatusSubscriber()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), paneAgentStatusSubscriber: status)

        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)

        XCTAssertEqual(
            Set(status.subscribed),
            [PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2"), PaneID(rawValue: "w1:p3")])
        XCTAssertTrue(status.unsubscribed.isEmpty)
    }

    @MainActor
    func testAgentStatusFeedsAreArmedOnceAndDisarmedAsPanesLeaveTheModel() {
        let status = FakePaneAgentStatusSubscriber()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), paneAgentStatusSubscriber: status)
        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)

        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)
        XCTAssertEqual(status.subscribed.count, 3, "an unchanged pane set re-arms nothing")

        var closed = makeModelWithAPaneInASecondTab()
        closed.panes.removeValue(forKey: PaneID(rawValue: "w1:p3"))
        viewModel.update(model: closed, connection: .live)

        XCTAssertEqual(status.unsubscribed, [PaneID(rawValue: "w1:p3")])
    }

    /// A dropped connection takes every feed with it; the next snapshot arms
    /// them again, each with a probe of its own.
    @MainActor
    func testLosingTheModelDisarmsEveryAgentStatusFeed() {
        let status = FakePaneAgentStatusSubscriber()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), paneAgentStatusSubscriber: status)
        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)

        viewModel.update(model: nil, connection: .reconnecting(attempt: 1))

        XCTAssertEqual(status.unsubscribed.count, 3, "an equality of two empty sets would prove nothing")
        XCTAssertEqual(Set(status.unsubscribed), Set(status.subscribed))
    }

    // MARK: - handing the panes back to herdr while flock is not in front

    /// Parked panes are the point, not an afterthought: a parked surface keeps
    /// its bridge attached, so it holds that pane's resize lock exactly as a
    /// visible one does.
    @MainActor
    func testReleasingTheHoldReachesEveryPaneIncludingTheParkedOnes() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let visible = PaneID(rawValue: "w1:p1")
        let parked = PaneID(rawValue: "w1:p2")

        _ = await viewModel.attachPane(visible)
        _ = await viewModel.attachPane(parked)
        await viewModel.detachPane(parked)

        viewModel.releaseHerdrHold()

        XCTAssertEqual(try XCTUnwrap(factory.surfaces[visible]).holdCalls, [.release])
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[parked]).holdCalls, [.release], "a parked pane kept its lock")
    }

    @MainActor
    func testTakingTheHoldBackReachesEveryPaneItWasReleasedFor() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let visible = PaneID(rawValue: "w1:p1")
        let parked = PaneID(rawValue: "w1:p2")

        _ = await viewModel.attachPane(visible)
        _ = await viewModel.attachPane(parked)
        await viewModel.detachPane(parked)

        viewModel.releaseHerdrHold()
        viewModel.takeHerdrHold()

        XCTAssertEqual(try XCTUnwrap(factory.surfaces[visible]).holdCalls, [.release, .take])
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[parked]).holdCalls, [.release, .take])
    }

    /// Nothing may be lost across the handoff. What that means on this side is
    /// that a release creates, parks and tears down nothing: the same surfaces
    /// come back, still warm, still in the same park order, and flock's own
    /// selection is where it was.
    @MainActor
    func testAHandoffCreatesParksAndTearsDownNothing() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let visible = PaneID(rawValue: "w1:p1")
        let parked = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(visible)
        _ = await viewModel.attachPane(parked)
        await viewModel.detachPane(parked)
        viewModel.select(workspace: WorkspaceID(rawValue: "w1"))
        let selectedBefore = viewModel.selectedWorkspaceID
        let visibleSurface = try XCTUnwrap(factory.surfaces[visible])
        let parkedSurface = try XCTUnwrap(factory.surfaces[parked])

        viewModel.releaseHerdrHold()
        viewModel.takeHerdrHold()

        XCTAssertEqual(factory.makeSurfaceCalls.count, 2, "the handoff built a surface")
        for surface in [visibleSurface, parkedSurface] {
            XCTAssertEqual(surface.detachCallCount, 0, "the handoff tore a surface down")
        }
        XCTAssertEqual(visibleSurface.parkCallCount, 0, "the handoff parked a visible pane")
        XCTAssertEqual(parkedSurface.parkCallCount, 1, "the handoff re-parked an already parked pane")
        XCTAssertEqual(parkedSurface.unparkCallCount, 0, "the handoff woke a parked pane")
        XCTAssertTrue(viewModel.ghosttySurface(for: visible) === visibleSurface)
        XCTAssertTrue(viewModel.ghosttySurface(for: parked) === parkedSurface, "the warm cache lost a pane")
        XCTAssertEqual(viewModel.selectedWorkspaceID, selectedBefore)
    }

    /// The release is deliberately not on the `paneWork` chain, so a surface
    /// whose attach lands after it was sent never sees it. A bridge spawns
    /// HOLDING, so that one pane would take its lock while flock is supposed
    /// to have let go: one pane refusing to follow the terminal while every
    /// other pane does, with nothing on screen to say so and no edge to fix it
    /// short of clicking into flock and away again.
    @MainActor
    func testAPaneAttachedAfterAReleaseIsToldToLetGoAsItRegisters() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let early = PaneID(rawValue: "w1:p1")
        let late = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(early)

        viewModel.releaseHerdrHold()
        _ = await viewModel.attachPane(late)

        XCTAssertEqual(try XCTUnwrap(factory.surfaces[late]).holdCalls, [.release])
        // And the take reaches it, so the pane is not left released either.
        viewModel.takeHerdrHold()
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[late]).holdCalls, [.release, .take])
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[early]).holdCalls, [.release, .take])
    }

    /// The other direction: a bridge spawns holding, so a cold attach while
    /// flock is active must not be sent a take it does not need.
    @MainActor
    func testAPaneAttachedWhileFlockHoldsIsSentNothing() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let pane = PaneID(rawValue: "w1:p1")

        _ = await viewModel.attachPane(pane)
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[pane]).holdCalls, [])

        viewModel.releaseHerdrHold()
        viewModel.takeHerdrHold()
        let after = PaneID(rawValue: "w1:p2")
        _ = await viewModel.attachPane(after)
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[after]).holdCalls, [], "the intent did not follow the take")
    }

    /// A pane whose surface was already torn down (the warm cap's eviction, or
    /// herdr closing it) has no hold to give back, and must not be reached.
    @MainActor
    func testAToreDownPaneIsNotSentAHoldCommand() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), ghosttyFactory: factory)
        let panes = (1...13).map { PaneID(rawValue: "w1:p\($0)") }
        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
        for pane in panes {
            await viewModel.detachPane(pane)
        }
        let evicted = try XCTUnwrap(factory.surfaces[panes[0]])

        viewModel.releaseHerdrHold()

        XCTAssertEqual(evicted.detachCallCount, 1, "the cap did not evict the pane this test is about")
        XCTAssertEqual(evicted.holdCalls, [], "a torn-down pane was sent a hold command")
        XCTAssertEqual(try XCTUnwrap(factory.surfaces[panes[12]]).holdCalls, [.release])
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
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane), "a freshly flock-created pane starts pristine")

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
    /// that also tells the surface to stop reporting. This is the seam; the
    /// rule that reads the counts is `PaneLauncherRegistryTests`.
    @MainActor
    func testScreenActivityThroughGhosttySeamHidesTheLauncherAndStopsFurtherReporting() async throws {
        let clock = TestClock()
        let factory = FakeGhosttyPaneFactory()
        let client = StubSplitCommandClient(newPaneID: "w1:p2")
        let viewModel = SessionViewModel(client: client, ghosttyFactory: factory, now: { clock.now })
        let pane = PaneID(rawValue: "w1:p2")

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane))

        _ = await viewModel.attachPane(pane)
        let onScreenActivity = try XCTUnwrap(factory.onScreenActivityHandlers[pane])

        // The shell's own startup, however many rows it prints: still
        // pristine, and the surface is told to keep reporting.
        XCTAssertTrue(onScreenActivity(1), "the shell is still starting up -- keep polling")
        clock.advance(0.25)
        XCTAssertTrue(onScreenActivity(4), "the shell is still starting up -- keep polling")
        XCTAssertTrue(viewModel.isPristineLauncherPane(pane))

        // Output the settled pane printed: hides the launcher, and tells the
        // surface to stop.
        clock.advance(PaneLauncherRegistry.settleWindow + 1)
        XCTAssertFalse(onScreenActivity(9), "output from a settled pane hides it -- stop polling")
        XCTAssertFalse(viewModel.isPristineLauncherPane(pane))

        // A later call (the surface's own throttle firing once more before
        // it notices the stop signal) must stay a harmless no-op.
        clock.advance(0.25)
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

    /// The common case is one pane among several, and it stays instant: a
    /// prompt on every close would be a prompt nobody reads. `w1:t1` holds
    /// `w1:p1` and `w1:p2`.
    @MainActor
    func testClosingAPaneWithSiblingsAsksNothing() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)

        await viewModel.closePane(PaneID(rawValue: "w1:p1"))

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.closePane(PaneID(rawValue: "w1:p1"))], label: "Close pane")])
    }

    /// `w1:p3` is the only pane of `w1:t2`, so herdr would take the tab with
    /// it, and a close cannot be undone.
    @MainActor
    func testClosingATabsLastPaneAsksBeforeSendingAnything() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)

        await viewModel.closePane(PaneID(rawValue: "w1:p3"))

        XCTAssertTrue(executor.executedPlans.isEmpty, "nothing may reach herdr before the answer")
        XCTAssertEqual(viewModel.pendingClose?.subject, .pane(PaneID(rawValue: "w1:p3")))
        XCTAssertEqual(viewModel.pendingClose?.title, "Close the tab \"second\"?")
    }

    /// The seeded model is one workspace of one tab of one pane, so this close
    /// takes the whole workspace.
    @MainActor
    func testConfirmingAPaneCloseSendsItAndTakesThePromptDown() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModel(), connection: .live)
        await viewModel.closePane(PaneID(rawValue: "w1:p1"))
        XCTAssertEqual(viewModel.pendingClose?.confirmButtonTitle, "Close Workspace")

        await viewModel.confirmClose(.pane(PaneID(rawValue: "w1:p1")))

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.closePane(PaneID(rawValue: "w1:p1"))], label: "Close pane")])
    }

    @MainActor
    func testCancellingAPaneCloseSendsNothing() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModel(), connection: .live)
        await viewModel.closePane(PaneID(rawValue: "w1:p1"))

        viewModel.cancelPendingClose()

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertTrue(executor.executedPlans.isEmpty)
    }

    /// A tab among other tabs is the common case for the other verb, and it
    /// stays instant: `w1` holds `w1:t1` and `w1:t2`.
    @MainActor
    func testClosingATabAmongTabsAsksNothing() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModelWithAPaneInASecondTab(), connection: .live)

        await viewModel.closeTab(TabID(rawValue: "w1:t2"))

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.closeTab(TabID(rawValue: "w1:t2"))], label: "Close tab")])
    }

    /// The seeded model is one workspace of one tab, so herdr would close the
    /// workspace outright. The prompt has to say which workspace.
    @MainActor
    func testClosingAWorkspacesLastTabAsksBeforeSendingAnything() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.closeTab(TabID(rawValue: "w1:t1"))

        XCTAssertTrue(executor.executedPlans.isEmpty, "nothing may reach herdr before the answer")
        XCTAssertEqual(viewModel.pendingClose?.subject, .tab(TabID(rawValue: "w1:t1")))
        XCTAssertEqual(viewModel.pendingClose?.title, "Close the workspace \"seed\"?")
        XCTAssertEqual(viewModel.pendingClose?.confirmButtonTitle, "Close Workspace")
    }

    @MainActor
    func testConfirmingATabCloseSendsItAndTakesThePromptDown() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModel(), connection: .live)
        await viewModel.closeTab(TabID(rawValue: "w1:t1"))

        await viewModel.confirmClose(.tab(TabID(rawValue: "w1:t1")))

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.closeTab(TabID(rawValue: "w1:t1"))], label: "Close tab")])
    }

    @MainActor
    func testCancellingATabCloseSendsNothing() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        viewModel.update(model: makeModel(), connection: .live)
        await viewModel.closeTab(TabID(rawValue: "w1:t1"))

        viewModel.cancelPendingClose()

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertTrue(executor.executedPlans.isEmpty)
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

    /// The rail counts its slot without Board's workspaces, so the names it
    /// set them aside by have to reach the planner with the drop.
    @MainActor
    func testPerformPlacesARailSlotWithBoardsWorkspacesSetAside() async {
        let executor = FakePlanExecutor()
        let viewModel = SessionViewModel(client: RecordingCommandClient(), planExecutor: executor)
        var model = makeModel()
        for (index, label) in ["Reviews", "deck", "notes"].enumerated() {
            model.workspaces.append(WorkspaceRecord(
                workspaceID: WorkspaceID(rawValue: "w\(index + 2)"), label: label, number: index + 2,
                activeTabID: TabID(rawValue: "w\(index + 2):t1"), agentStatus: .idle
            ))
        }
        viewModel.update(model: model, connection: .live)
        let board = BoardWorkspaceNames(reviews: "Reviews", responds: "Responses", doctors: "Doctors")

        let outcome = await viewModel.perform(subject: .workspace(WorkspaceID(rawValue: "w4")), target: .workspaceRail(insertIndex: 1), board: board)

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(executor.executedPlans.map(\.ops), [[.moveWorkspace(WorkspaceID(rawValue: "w4"), insertIndex: 2)]])
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

        // The seam FlockApp's `.onChange(of: herdrStore.model)` calls into:
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
    func testAPaneDroppedIntoAnotherTabIsFocusedSoFlockFollowsIt() async {
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

    /// A pane target names a pane, never a tab, so whether the drop leaves the
    /// tab is the model's answer. On the canvas the target is always a pane of
    /// the drag's own tab; a grid drop can aim one at any tab's mini pane.
    func testOnlyDropsThatLeaveTheTabFollowThePane() {
        let pane = PaneID(rawValue: "w1:p1")
        let sibling = PaneID(rawValue: "w1:p2")
        let elsewhere = PaneID(rawValue: "w1:p3")
        let model = makeModelWithAPaneInASecondTab()
        XCTAssertTrue(DropTarget.tabThumbnail(TabID(rawValue: "w1:t2")).takesThePaneOffItsTab(pane, model: model))
        XCTAssertTrue(DropTarget.newTab(WorkspaceID(rawValue: "w1")).takesThePaneOffItsTab(pane, model: model))
        XCTAssertTrue(DropTarget.workspaceThumbnail(WorkspaceID(rawValue: "w2")).takesThePaneOffItsTab(pane, model: model))
        XCTAssertTrue(DropTarget.newWorkspace.takesThePaneOffItsTab(pane, model: model))
        XCTAssertFalse(DropTarget.paneEdge(sibling, .left).takesThePaneOffItsTab(pane, model: model))
        XCTAssertFalse(DropTarget.paneInterior(sibling).takesThePaneOffItsTab(pane, model: model))
        XCTAssertTrue(
            DropTarget.paneEdge(elsewhere, .left).takesThePaneOffItsTab(pane, model: model),
            "a mini pane of another tab takes the pane off this one"
        )
        XCTAssertTrue(DropTarget.paneInterior(elsewhere).takesThePaneOffItsTab(pane, model: model))
        XCTAssertFalse(DropTarget.tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0).takesThePaneOffItsTab(pane, model: model))
        XCTAssertFalse(DropTarget.workspaceRail(insertIndex: 0).takesThePaneOffItsTab(pane, model: model))
        XCTAssertFalse(DropTarget.moreTabs(WorkspaceID(rawValue: "w1")).takesThePaneOffItsTab(pane, model: model))
    }

    // MARK: - Inline rename

    @MainActor
    private func renameHarness(
        model: SessionModel = makeModel()
    ) -> (viewModel: SessionViewModel, executor: FakePlanExecutor, journal: UndoJournal, notices: NoticeRecorder) {
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { model }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(
            client: RecordingCommandClient(), planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) }
        )
        viewModel.update(model: model, connection: .live)
        return (viewModel, executor, journal, notices)
    }

    @MainActor
    func testBeginRenameOpensExactlyOneEditorAndCancelClosesIt() {
        let harness = renameHarness()
        XCTAssertNil(harness.viewModel.renameTarget)

        harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t1")))
        XCTAssertEqual(harness.viewModel.renameTarget, .tab(TabID(rawValue: "w1:t1")))

        harness.viewModel.beginRename(.pane(PaneID(rawValue: "w1:p1")))
        XCTAssertEqual(harness.viewModel.renameTarget, .pane(PaneID(rawValue: "w1:p1")), "a second editor replaces the first")

        harness.viewModel.cancelRename()
        XCTAssertNil(harness.viewModel.renameTarget)
    }

    @MainActor
    func testACancelledRenameIssuesNothing() async {
        let harness = renameHarness()
        harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t1")))

        harness.viewModel.cancelRename()

        XCTAssertTrue(harness.executor.executedPlans.isEmpty)
        XCTAssertFalse(harness.journal.canUndo)
    }

    @MainActor
    func testCommittingATrimmedLabelRunsTheRenameAndRecordsIt() async {
        let harness = renameHarness()
        harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t1")))

        await harness.viewModel.commitRename("  api  ", for: .tab(TabID(rawValue: "w1:t1")))

        XCTAssertEqual(
            harness.executor.executedPlans,
            [OpPlan(ops: [.renameTab(TabID(rawValue: "w1:t1"), "api")], label: "Rename tab")]
        )
        XCTAssertEqual(harness.journal.undoLabel, "Rename tab")
        XCTAssertNil(harness.viewModel.renameTarget, "the editor closes on commit")
    }

    /// The blank and unchanged cases still close the editor; what they must
    /// not do is reach the executor at all.
    @MainActor
    func testCommittingBlankOrUnchangedTextClosesTheEditorAndRunsNothing() async {
        for text in ["   ", "orig"] {
            let harness = renameHarness()
            harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t1")))

            await harness.viewModel.commitRename(text, for: .tab(TabID(rawValue: "w1:t1")))

            XCTAssertTrue(harness.executor.executedPlans.isEmpty, text.debugDescription)
            XCTAssertFalse(harness.journal.canUndo, text.debugDescription)
            XCTAssertNil(harness.viewModel.renameTarget, text.debugDescription)
        }
    }

    @MainActor
    func testTheEditorOpensOnWhateverTheModelCurrentlyShows() {
        let harness = renameHarness()

        XCTAssertEqual(harness.viewModel.renameText(for: .tab(TabID(rawValue: "w1:t1"))), "orig")
        XCTAssertEqual(harness.viewModel.renameText(for: .workspace(WorkspaceID(rawValue: "w1"))), "seed")
        XCTAssertEqual(harness.viewModel.renameText(for: .pane(PaneID(rawValue: "w1:p1"))), "", "the fixture pane has no manual label")
    }

    @MainActor
    func testClearPaneNameSendsANullLabelOnlyForAPaneThatHasOne() async throws {
        let unlabelled = renameHarness()
        await unlabelled.viewModel.clearPaneName(PaneID(rawValue: "w1:p1"))
        XCTAssertTrue(unlabelled.executor.executedPlans.isEmpty, "nothing to clear")

        var model = makeModel()
        let pane = PaneID(rawValue: "w1:p1")
        let existing = try XCTUnwrap(model.panes[pane])
        model.panes[pane] = PaneRecord(
            paneID: existing.paneID, workspaceID: existing.workspaceID, tabID: existing.tabID, focused: existing.focused,
            agentStatus: existing.agentStatus, revision: existing.revision, terminalTitleStripped: existing.terminalTitleStripped,
            label: "build", cwd: existing.cwd, scroll: existing.scroll
        )
        let labelled = renameHarness(model: model)

        await labelled.viewModel.clearPaneName(pane)

        XCTAssertEqual(labelled.executor.executedPlans, [OpPlan(ops: [.renamePane(pane, nil)], label: "Clear pane name")])
    }

    // MARK: - Zoom

    /// Zoom's own inverse is itself, so journaling it would only ever leave a
    /// dead undo step that reports nothing to undo.
    @MainActor
    func testZoomRunsThroughTheExecutorButIsNeverJournaled() async {
        let harness = renameHarness()

        await harness.viewModel.toggleZoom(PaneID(rawValue: "w1:p1"))

        XCTAssertEqual(
            harness.executor.executedPlans,
            [OpPlan(ops: [.zoom(PaneID(rawValue: "w1:p1"), mode: .toggle)], label: "Zoom pane")]
        )
        XCTAssertFalse(harness.journal.canUndo)
    }

    // MARK: - Close tab / workspace, and the group-close prompt

    /// A two-tab workspace, so this close takes the tab and no more. A tab
    /// that is its workspace's last goes through the prompt instead
    /// (`testClosingAWorkspacesLastTabAsksBeforeSendingAnything`).
    @MainActor
    func testClosingATabRunsAndRecordsIt() async {
        let harness = renameHarness(model: makeModelWithAPaneInASecondTab())

        await harness.viewModel.closeTab(TabID(rawValue: "w1:t2"))

        XCTAssertEqual(harness.executor.executedPlans, [OpPlan(ops: [.closeTab(TabID(rawValue: "w1:t2"))], label: "Close tab")])
        XCTAssertEqual(harness.journal.undoLabel, "Close tab")
    }

    @MainActor
    func testClosingAWorkspaceAsksWithoutTheGroupFirst() async {
        let harness = renameHarness()

        await harness.viewModel.closeWorkspace(WorkspaceID(rawValue: "w1"))

        XCTAssertEqual(
            harness.executor.executedPlans,
            [OpPlan(ops: [.closeWorkspace(WorkspaceID(rawValue: "w1"), closeGroup: false)], label: "Close workspace")]
        )
        XCTAssertNil(harness.viewModel.pendingGroupClose)
    }

    /// Drives the refusal herdr gives a group primary with open linked
    /// worktrees, so each test below starts from a parked prompt.
    @MainActor
    private func parkedGroupClose(
        _ harness: (viewModel: SessionViewModel, executor: FakePlanExecutor, journal: UndoJournal, notices: NoticeRecorder),
        workspace: WorkspaceID
    ) async {
        harness.executor.nextResult = .failure(OpFailure(
            failedOp: .closeWorkspace(workspace, closeGroup: false),
            code: "workspace_group_close_required", message: "workspace_group_close_required",
            executed: [], partialInverse: OpPlan(ops: [], label: "Undo Close workspace")
        ))
        await harness.viewModel.closeWorkspace(workspace)
        harness.executor.nextResult = nil
    }

    /// herdr refuses a plain close on a group primary with open linked
    /// worktrees. That one failure raises no toast: it parks the workspace
    /// for the confirmation instead, with the label the prompt prints.
    @MainActor
    func testAGroupCloseRequiredRefusalParksTheWorkspaceAndRaisesNoNotice() async {
        let harness = renameHarness()
        let workspace = WorkspaceID(rawValue: "w1")

        await parkedGroupClose(harness, workspace: workspace)

        XCTAssertEqual(harness.viewModel.pendingGroupClose?.workspaceID, workspace)
        XCTAssertEqual(harness.viewModel.pendingGroupClose?.label, "seed", "the prompt has to name what it is about to close")
        XCTAssertTrue(harness.notices.messages.isEmpty, "the prompt is the answer, not a toast")
        XCTAssertFalse(harness.journal.canUndo)
    }

    @MainActor
    func testConfirmingTheGroupCloseReAsksWithTheGroupIncluded() async {
        let harness = renameHarness()
        let workspace = WorkspaceID(rawValue: "w1")
        await parkedGroupClose(harness, workspace: workspace)

        await harness.viewModel.confirmGroupClose(workspace)

        XCTAssertEqual(harness.executor.executedPlans.map(\.ops), [
            [.closeWorkspace(workspace, closeGroup: false)],
            [.closeWorkspace(workspace, closeGroup: true)],
        ])
        XCTAssertEqual(harness.executor.executedPlans.last?.label, "Close workspace group")
        XCTAssertNil(harness.viewModel.pendingGroupClose)
    }

    /// The ordering a real confirmation dialog produces: it clears its own
    /// presentation state as it dismisses, which runs BEFORE the button's
    /// enqueued work does. The confirm therefore takes the workspace as a
    /// parameter and must not read the latch back -- if it did, this would
    /// close nothing at all, silently.
    @MainActor
    func testTheConfirmRunsEvenThoughTheDismissalAlreadyClearedTheLatch() async {
        let harness = renameHarness()
        let workspace = WorkspaceID(rawValue: "w1")
        await parkedGroupClose(harness, workspace: workspace)

        harness.viewModel.cancelPendingGroupClose()
        XCTAssertNil(harness.viewModel.pendingGroupClose, "the dialog's own dismissal ran first")
        await harness.viewModel.confirmGroupClose(workspace)

        XCTAssertEqual(
            harness.executor.executedPlans.last?.ops, [.closeWorkspace(workspace, closeGroup: true)],
            "the confirm read the workspace back off the cleared latch instead of its parameter"
        )
    }

    @MainActor
    func testDecliningTheGroupCloseClosesNothing() async {
        let harness = renameHarness()
        let workspace = WorkspaceID(rawValue: "w1")
        await parkedGroupClose(harness, workspace: workspace)

        harness.viewModel.cancelPendingGroupClose()

        XCTAssertEqual(harness.executor.executedPlans.count, 1, "only the refused first ask ever ran")
        XCTAssertNil(harness.viewModel.pendingGroupClose)
    }

    /// Every OTHER close failure keeps its toast: only the group-close code
    /// is swallowed in favor of a prompt.
    @MainActor
    func testAnUnrelatedCloseFailureStillRaisesItsNotice() async {
        let harness = renameHarness()
        let workspace = WorkspaceID(rawValue: "w1")
        harness.executor.nextResult = .failure(OpFailure(
            failedOp: .closeWorkspace(workspace, closeGroup: false),
            code: "workspace_not_found", message: "workspace_not_found",
            executed: [], partialInverse: OpPlan(ops: [], label: "Undo Close workspace")
        ))

        await harness.viewModel.closeWorkspace(workspace)

        XCTAssertEqual(harness.notices.messages, ["Close workspace failed: workspace_not_found"])
        XCTAssertNil(harness.viewModel.pendingGroupClose)
    }

    // MARK: - Creation (direct client calls, never planned ops)

    /// The strip and rail create from a zone that draws nothing, so a
    /// swallowed failure is indistinguishable from a click that missed, and
    /// the retry it invites spawns a second real shell.
    @MainActor
    func testACreationFailureRaisesItsOwnNotice() async {
        let notices = NoticeRecorder()
        let viewModel = SessionViewModel(client: ServerErrorCommandClient(), noticeSink: { notices.record($0) })
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))
        await viewModel.createWorkspace()

        XCTAssertEqual(notices.messages, ["New tab failed: no such workspace", "New workspace failed: no such workspace"])
    }

    /// What "New Tab" means to the person who pressed Cmd+T: the new tab is
    /// the one on screen and its shell is the one taking keystrokes. herdr is
    /// asked to focus it (`focus: true`), but that only moves flock's own
    /// selection once the focus echo arrives, which is a round trip later at
    /// best and never at all if herdr emits no `tab.focused` for a create.
    @MainActor
    func testCreatingATabLandsInItWithoutWaitingForHerdrsEcho() async {
        let viewModel = SessionViewModel(client: StubCreateCommandClient(tabID: "w1:t2", paneID: "w1:p2"))
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t2"), "the new tab is not the one being shown")
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
        XCTAssertEqual(
            viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w1:p2"),
            "the new tab's shell is not the pane taking keystrokes")
        XCTAssertTrue(
            viewModel.isPristineLauncherPane(PaneID(rawValue: "w1:p2")),
            "a tab flock created offers the launcher, the same as a split does")
    }

    /// A snapshot that does not move herdr's focused tab must not drag the
    /// selection back off the tab just created: the echo may be several
    /// unrelated updates away.
    @MainActor
    func testACreatedTabStaysSelectedThroughUnrelatedUpdates() async {
        let viewModel = SessionViewModel(client: StubCreateCommandClient(tabID: "w1:t2", paneID: "w1:p2"))
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: makeModel(), connection: .live)

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t2"))
    }

    /// `workspace.create` answers with the first tab of the new workspace, so
    /// the rail's create lands the same way the strip's does -- including the
    /// workspace, which a tab create leaves alone.
    @MainActor
    func testCreatingAWorkspaceLandsInItsFirstTab() async {
        let viewModel = SessionViewModel(client: StubCreateCommandClient(workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1"))
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.createWorkspace()

        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w2:t1"))
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, PaneID(rawValue: "w2:p1"))
        XCTAssertTrue(viewModel.isPristineLauncherPane(PaneID(rawValue: "w2:p1")))
    }

    @MainActor
    func testCreatingATabAndAWorkspaceAreDirectClientCallsWithNoPlanAndNoUndo() async {
        let client = RecordingCommandClient()
        let executor = FakePlanExecutor()
        let notices = NoticeRecorder()
        let journal = UndoJournal(executor: executor, model: { makeModel() }, notify: { notices.record($0) })
        let viewModel = SessionViewModel(client: client, planExecutor: executor, undoJournal: journal, noticeSink: { notices.record($0) })
        viewModel.update(model: makeModel(), connection: .live)

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))
        await viewModel.createWorkspace()

        let calls = await client.calls
        XCTAssertEqual(calls.map(\.method), ["tab.create", "workspace.create"])
        XCTAssertEqual(stringParam(calls[0].params, "workspace_id"), "w1")
        XCTAssertEqual(boolParam(calls[0].params, "focus"), true)
        XCTAssertEqual(stringParam(calls[1].params, "source_workspace_id"), "w1")
        XCTAssertEqual(boolParam(calls[1].params, "focus"), true)
        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertFalse(journal.canUndo)
    }

    // MARK: - Menu and keyboard commands compile the drag's own plans

    /// The whole point of the Move to... submenu: picking a destination must
    /// produce byte-for-byte the plan the equivalent drag would.
    @MainActor
    func testAMoveToSelectionCompilesTheIdenticalPlanTheDragWould() async {
        let model = makeModelWithAPaneInASecondTab()
        let harness = renameHarness(model: model)
        let pane = PaneID(rawValue: "w1:p1")
        let target = DropTarget.tabThumbnail(TabID(rawValue: "w1:t2"))
        guard case .success(let expected) = plan(dragging: .pane(pane), onto: target, model: model) else {
            return XCTFail("the fixture drag plans nothing, so this proves nothing")
        }

        await PaneMenuAction.moveTo(target).perform(paneID: pane, on: harness.viewModel)

        XCTAssertEqual(harness.executor.executedPlans, [expected])
    }

    /// Two panes side by side in one tab, with herdr focused on the right
    /// one: what a keyboard move has to aim at.
    private static func sideBySideModel() -> SessionModel {
        var model = makeModelWithAPaneInASecondTab()
        model.focusedPaneID = PaneID(rawValue: "w1:p2")
        model.layouts[TabID(rawValue: "w1:t1")] = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneID: PaneID(rawValue: "w1:p2"),
            panes: [
                PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: false, rect: CellRect(x: 0, y: 0, width: 40, height: 24)),
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: true, rect: CellRect(x: 40, y: 0, width: 40, height: 24)),
            ],
            splits: [SplitInfo(id: "split_0_root", direction: .right, ratio: 0.5, rect: CellRect(x: 0, y: 0, width: 80, height: 24))]
        )
        return model
    }

    @MainActor
    func testAKeyboardMoveCompilesTheSamePlanAsTheDragOntoThatNeighborsEdge() async {
        let model = Self.sideBySideModel()
        let harness = renameHarness(model: model)
        let pane = PaneID(rawValue: "w1:p2")
        let target = DropTarget.paneEdge(PaneID(rawValue: "w1:p1"), .left)
        guard case .success(let expected) = plan(dragging: .pane(pane), onto: target, model: model) else {
            return XCTFail("the fixture drag plans nothing, so this proves nothing")
        }

        await harness.viewModel.movePane(pane, toward: .left)

        XCTAssertEqual(harness.executor.executedPlans, [expected])
    }

    /// The swap binding aims at the SAME neighbor and differs only in what it
    /// does there: an interior, which the planner turns into `pane.swap`
    /// rather than the move's temp-tab bounce.
    @MainActor
    func testAKeyboardSwapCompilesTheSamePlanAsADropOnThatNeighborsInterior() async {
        let model = Self.sideBySideModel()
        let harness = renameHarness(model: model)
        let pane = PaneID(rawValue: "w1:p2")
        let target = DropTarget.paneInterior(PaneID(rawValue: "w1:p1"))
        guard case .success(let expected) = plan(dragging: .pane(pane), onto: target, model: model) else {
            return XCTFail("the fixture drag plans nothing, so this proves nothing")
        }
        XCTAssertEqual(expected.ops, [.swapPanes(pane, PaneID(rawValue: "w1:p1"))], "a same-tab interior is a swap, not a move")

        await harness.viewModel.swapFocusedPane(toward: .left)

        XCTAssertEqual(harness.executor.executedPlans, [expected])
    }

    @MainActor
    func testAKeyboardMoveWithNothingThatWayRunsNothingAndReportsItselfUnavailable() async {
        let harness = renameHarness(model: Self.sideBySideModel())

        XCTAssertTrue(harness.viewModel.focusedPaneHasNeighbor(toward: .left), "w1:p2 is focused with w1:p1 to its left")
        XCTAssertFalse(harness.viewModel.focusedPaneHasNeighbor(toward: .right))
        XCTAssertFalse(harness.viewModel.focusedPaneHasNeighbor(toward: .up))

        await harness.viewModel.moveFocusedPane(toward: .right)
        await harness.viewModel.swapFocusedPane(toward: .right)

        XCTAssertTrue(harness.executor.executedPlans.isEmpty, "neither binding fires where there is no neighbor")
    }

    // MARK: - The rename key (F2)

    @MainActor
    func testTheRenameKeyTakesTheInnermostSelection() {
        let harness = renameHarness(model: Self.sideBySideModel())

        XCTAssertEqual(harness.viewModel.renameShortcutTarget, .pane(PaneID(rawValue: "w1:p2")))

        harness.viewModel.beginRenameFromShortcut()

        XCTAssertEqual(harness.viewModel.renameTarget, .pane(PaneID(rawValue: "w1:p2")))
    }

    /// The fallbacks, decided in `RenameShortcut` and read through the view
    /// model's own selection, so the key still renames something when no pane
    /// is focused.
    @MainActor
    func testTheRenameKeyFallsBackToTheTabThenTheWorkspaceThenNothing() {
        XCTAssertEqual(
            RenameShortcut.target(focusedPane: nil, selectedTab: TabID(rawValue: "w1:t1"), selectedWorkspace: WorkspaceID(rawValue: "w1")),
            .tab(TabID(rawValue: "w1:t1"))
        )
        XCTAssertEqual(
            RenameShortcut.target(focusedPane: nil, selectedTab: nil, selectedWorkspace: WorkspaceID(rawValue: "w1")),
            .workspace(WorkspaceID(rawValue: "w1"))
        )
        XCTAssertNil(RenameShortcut.target(focusedPane: nil, selectedTab: nil, selectedWorkspace: nil))
    }

    @MainActor
    func testTheRenameKeyOpensNothingWithNoSelectionAtAll() {
        let viewModel = SessionViewModel(client: RecordingCommandClient())

        XCTAssertNil(viewModel.renameShortcutTarget, "the menu item disables itself on this")
        viewModel.beginRenameFromShortcut()

        XCTAssertNil(viewModel.renameTarget)
    }

    // MARK: - The editor closes when what it names goes away

    @MainActor
    func testAnOpenEditorClosesWhenHerdrNoLongerCarriesItsTarget() {
        let harness = renameHarness()
        harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t1")))

        var withoutTheTab = makeModel()
        withoutTheTab.tabs[WorkspaceID(rawValue: "w1")] = []
        harness.viewModel.update(model: withoutTheTab, connection: .live)

        XCTAssertNil(harness.viewModel.renameTarget)
    }

    /// A dropped connection is a transient gap, not evidence the target is
    /// gone -- the same reading the undo journal gives a nil model. Losing a
    /// half-typed name to a reconnect would be the worse answer.
    @MainActor
    func testAnOpenEditorSurvivesTheModelGoingNil() {
        let harness = renameHarness()
        harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t1")))

        harness.viewModel.update(model: nil, connection: .reconnecting(attempt: 1))

        XCTAssertEqual(harness.viewModel.renameTarget, .tab(TabID(rawValue: "w1:t1")))
    }

    @MainActor
    func testAnOpenEditorSurvivesAnUpdateThatStillCarriesItsTarget() {
        let harness = renameHarness()
        harness.viewModel.beginRename(.workspace(WorkspaceID(rawValue: "w1")))

        harness.viewModel.update(model: makeModel(), connection: .live)

        XCTAssertEqual(harness.viewModel.renameTarget, .workspace(WorkspaceID(rawValue: "w1")))
    }

    @MainActor
    func testTheKeyboardMoveActsOnHerdrsFocusedPane() async {
        let model = Self.sideBySideModel()
        let harness = renameHarness(model: model)
        let target = DropTarget.paneEdge(PaneID(rawValue: "w1:p1"), .left)
        guard case .success(let expected) = plan(dragging: .pane(PaneID(rawValue: "w1:p2")), onto: target, model: model) else {
            return XCTFail("the fixture drag plans nothing, so this proves nothing")
        }

        await harness.viewModel.moveFocusedPane(toward: .left)

        XCTAssertEqual(harness.executor.executedPlans, [expected])
    }

    /// herdr's own reply shape, from `PaneReadResult` in its api schema:
    /// the payload sits under `read`, beside the source, format and revision.
    @MainActor
    func testTheLastLineIsReadFromHerdrsOwnReplyShape() throws {
        let reply = Data("""
        {"id":"1","result":{"read":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",\
        "source":"visible","format":"text","text":"building\\nready for input",\
        "revision":42,"truncated":false}}}
        """.utf8)

        XCTAssertEqual(SessionViewModel.extractLastLine(reply), "ready for input")
    }

    @MainActor
    func testAReplyWithNoReadPayloadLeavesTheCardWithoutALine() throws {
        let reply = Data(#"{"id":"1","result":{"text":"ready for input"}}"#.utf8)

        XCTAssertNil(SessionViewModel.extractLastLine(reply))
    }

    // MARK: - flock-owned workspaces

    @MainActor
    func testFlockOwnedWorkspacesStayInTheFullModelOnly() {
        let viewModel = SessionViewModel(client: RecordingCommandClient(), rt: makeCoordinator(FakeRtWorld()))
        viewModel.update(model: makeModelWithFlockWorkspace(), connection: .live)

        XCTAssertEqual(viewModel.model?.workspaces.map(\.workspaceID), [WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(viewModel.fullModel?.workspaces.count, 2)
    }

    @MainActor
    func testHerdrFocusLandingInAFlockOwnedTabLeavesTheSelectionAlone() {
        let viewModel = SessionViewModel(client: RecordingCommandClient(), rt: makeCoordinator(FakeRtWorld()))
        viewModel.update(model: makeModelWithFlockWorkspace(), connection: .live)
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))

        viewModel.update(
            model: makeModelWithFlockWorkspace(focusedWorkspaceID: "wF", focusedTabID: "wF:t1", focusedPaneID: "wF:p1"),
            connection: .live
        )

        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"))
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
    }

    /// A hidden pane's surface lives in the modal, not the canvas, and has to
    /// be torn down when herdr closes it like any other.
    @MainActor
    func testAHiddenPaneThatClosesIsTornDown() async throws {
        let factory = FakeGhosttyPaneFactory()
        let viewModel = SessionViewModel(
            client: RecordingCommandClient(), ghosttyFactory: factory, rt: makeCoordinator(FakeRtWorld())
        )
        viewModel.update(model: makeModelWithFlockWorkspace(), connection: .live)
        _ = await viewModel.attachPane(PaneID(rawValue: "wF:p1"))

        viewModel.update(model: makeModelWithFlockWorkspace(includingFlockPane: false), connection: .live)
        await viewModel.waitForClosedPaneTeardown()

        XCTAssertEqual(factory.surfaces[PaneID(rawValue: "wF:p1")]?.detachCallCount, 1)
    }

    // MARK: - rt

    @MainActor
    func testTheRtCoordinatorHearsTheFullModel() async {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "nav term_a1 old", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)
        let viewModel = SessionViewModel(client: RecordingCommandClient(), rt: rt)

        viewModel.update(model: world.model(), connection: .live)
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wS:t1")
    }

    /// The modal's surface takes the keyboard; no canvas pane may also claim it.
    @MainActor
    func testTheCanvasHasNoFocusedPaneWhileTheModalIsUp() async {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        let viewModel = SessionViewModel(client: RecordingCommandClient(), rt: rt)
        viewModel.update(model: world.model(), connection: .live)
        XCTAssertEqual(viewModel.canvasFocusedPaneID, RtFixture.linkedPaneID)

        await rt.open(.glitter, from: world.fixture.linkedPane)
        XCTAssertNil(viewModel.canvasFocusedPaneID)

        await rt.closeModal()
        XCTAssertEqual(viewModel.canvasFocusedPaneID, RtFixture.linkedPaneID)
    }
}
