import XCTest
@testable import PaddockCore

private actor RecordingCommandClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        return Data("{}".utf8)
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
}
