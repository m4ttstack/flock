import XCTest
@testable import FlockCore

private actor RecordingClient: HerdrCommandClient {
    private(set) var calls: [String] = []
    /// Each focus request as "method id".
    private(set) var focuses: [String] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append(method)
        if method.hasSuffix(".focus"), case .string(let id)? = params["pane_id"] ?? params["tab_id"] ?? params["workspace_id"] {
            focuses.append("\(method) \(id)")
        }
        return Data("{}".utf8)
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
final class MissionJumpTests: XCTestCase {
    private func model(_ statuses: [AgentStatus]) -> SessionModel {
        MissionFixture.model([
            .init(label: "home", tabs: [.init(label: "main", panes: [.init(status: .idle)])]),
            .init(label: "acme", tabs: [.init(label: "api", panes: statuses.map { .init(status: $0) })]),
        ], focusedPane: "w1:t1:p1")
    }

    func testEveryUpdateFeedsTheStatusHistory() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: model([.working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(120)
        viewModel.update(model: model([.blocked]), connection: .live)
        XCTAssertEqual(viewModel.statusHistory.lastChange(of: PaneID(rawValue: "w2:t1:p1")), clock.now)
    }

    func testJumpingToAPaneFocusesIt() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: model([.working]), connection: .live)
        await viewModel.jumpToPane(PaneID(rawValue: "w2:t1:p1"))
        let calls = await client.calls
        XCTAssertEqual(calls, ["tab.focus", "pane.focus"])
    }

    func testOverviewsOldestCardIsTheOldestOfAllNotTheOldestTheDockDraws() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.attentionCardLimit = 1
        viewModel.update(model: model([.working, .working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked, .working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked, .blocked]), connection: .live)
        XCTAssertEqual(viewModel.oldestAttentionPane, PaneID(rawValue: "w2:t1:p1"))
    }

    func testTheNextCardIsTheOldestOtherThanTheShownPane() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: model([.working, .working, .working]), connection: .live)
        for count in 1...3 {
            clock.now = clock.now.addingTimeInterval(10)
            viewModel.update(model: model(Array(repeating: .blocked, count: count) + Array(repeating: .working, count: 3 - count)), connection: .live)
        }
        let stack = viewModel.attentionToasts
        let first = PaneID(rawValue: "w2:t1:p1"), second = PaneID(rawValue: "w2:t1:p2")
        XCTAssertEqual(stack.oldest(excluding: nil)?.paneID, first)
        XCTAssertEqual(stack.oldest(excluding: first)?.paneID, second)
        XCTAssertEqual(stack.count(excluding: first), 2)
        XCTAssertEqual(stack.count(excluding: PaneID(rawValue: "w1:t1:p1")), 3)
        XCTAssertNil(AttentionToastStack().oldest(excluding: first))
    }

    func testFocusingInOverviewDismissesTheCardAndLeavesTheMoveToShowingIt() async {
        let clock = Clock()
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client, now: { clock.now })
        viewModel.update(model: model([.working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked]), connection: .live)
        let pane = PaneID(rawValue: "w2:t1:p1")
        XCTAssertEqual(viewModel.oldestAttentionPane, pane)
        XCTAssertTrue(viewModel.focusInOverview(pane: pane))
        XCTAssertNil(viewModel.attentionToasts.toast(pane: pane))
        XCTAssertNil(viewModel.oldestAttentionPane)
        let calls = await client.calls
        XCTAssertEqual(calls, [], "herdr's focus moved before the pane was shown")
        XCTAssertFalse(viewModel.focusInOverview(pane: PaneID(rawValue: "gone")))
    }

    /// The pane in Overview's focused view is being watched, as the main
    /// window's focused pane is: it raises no card while it is shown.
    func testThePaneShownInOverviewRaisesNoCardUntilItIsLeft() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        let pane = PaneID(rawValue: "w2:t1:p1")
        viewModel.update(model: model([.working]), connection: .live)
        viewModel.paneShownInOverview = pane
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked]), connection: .live)
        XCTAssertNil(viewModel.attentionToasts.toast(pane: pane), "the watched pane raised a card")
        viewModel.paneShownInOverview = nil
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked]), connection: .live)
        XCTAssertNotNil(viewModel.attentionToasts.toast(pane: pane), "a pane no longer shown raised no card")
    }

    /// A pane that blocked while shown raises its card as soon as it is left,
    /// so going back to the lanes finds it in Needs you, not At rest.
    func testLeavingAShownPaneThatBlockedRaisesItsCard() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        let pane = PaneID(rawValue: "w2:t1:p1")
        viewModel.update(model: model([.working]), connection: .live)
        viewModel.isMainCanvasCovered = true
        viewModel.paneShownInOverview = pane
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked]), connection: .live)
        XCTAssertNil(viewModel.attentionToasts.toast(pane: pane))
        viewModel.paneShownInOverview = nil
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: pane)?.kind, .needsInput)
    }

    private func focusedModel(_ status: AgentStatus) -> SessionModel {
        MissionFixture.model([
            .init(label: "home", tabs: [.init(label: "main", panes: [.init(status: .idle)])]),
            .init(label: "acme", tabs: [.init(label: "api", panes: [.init(status: status)])]),
        ], focusedPane: "w2:t1:p1")
    }

    /// The main window's focused pane is watched only while its canvas is on
    /// screen.
    func testTheFocusedPaneRaisesNoCardWhileTheMainCanvasIsShown() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: focusedModel(.working), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: focusedModel(.blocked), connection: .live)
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
    }

    func testTheFocusedPaneRaisesACardWhileTheGridCoversTheCanvas() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: focusedModel(.working), connection: .live)
        viewModel.isMainCanvasCovered = true
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: focusedModel(.blocked), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p1"))?.kind, .needsInput)
    }

    func testOpeningTheGridRaisesTheCardTheFocusedPaneHeldBack() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: focusedModel(.working), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: focusedModel(.blocked), connection: .live)
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
        clock.now = clock.now.addingTimeInterval(30)
        viewModel.isMainCanvasCovered = true
        let toast = viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p1"))
        XCTAssertEqual(toast?.kind, .needsInput)
        XCTAssertEqual(toast?.raisedAt, clock.now)
        viewModel.isMainCanvasCovered = false
        viewModel.sweepAttentionToasts()
        XCTAssertNotNil(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p1")), "a look is not an answer")
    }

    func testOpeningTheGridRaisesADoneFocusedPaneButNotAnIdleOne() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: focusedModel(.done), connection: .live)
        viewModel.isMainCanvasCovered = true
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p1"))?.kind, .finished)

        let quiet = SessionViewModel(client: RecordingClient(), now: { clock.now })
        quiet.update(model: focusedModel(.idle), connection: .live)
        quiet.isMainCanvasCovered = true
        XCTAssertTrue(quiet.attentionToasts.isEmpty)
    }

    /// Overview and Arrange cover the main canvas, so the keys that split,
    /// zoom or move its focused pane would act on a tab nobody can see.
    func testTheMainCanvasHasNoFocusedPaneWhileTheGridCoversIt() {
        let viewModel = SessionViewModel(client: RecordingClient())
        let pane = PaneID(rawValue: "w2:t1:p1")
        viewModel.update(model: focusedModel(.working), connection: .live)
        XCTAssertEqual(viewModel.canvasFocusedPaneID, pane)

        viewModel.isMainCanvasCovered = true
        XCTAssertNil(viewModel.canvasFocusedPaneID)
        XCTAssertFalse(viewModel.canvasFocusedPaneIsZoomed)

        viewModel.isMainCanvasCovered = false
        XCTAssertEqual(viewModel.canvasFocusedPaneID, pane)
    }

    /// The pane-only keys (close, right clicks) follow the pane on screen:
    /// Overview's focused pane, and none on its cards or in Arrange.
    func testThePaneOnlyKeysFollowThePaneOverviewShows() {
        let viewModel = SessionViewModel(client: RecordingClient())
        let pane = PaneID(rawValue: "w2:t1:p1")
        viewModel.update(model: focusedModel(.working), connection: .live)
        XCTAssertEqual(viewModel.shownFocusedPaneID, pane)

        viewModel.isMainCanvasCovered = true
        XCTAssertNil(viewModel.shownFocusedPaneID)

        viewModel.paneShownInOverview = pane
        XCTAssertEqual(viewModel.shownFocusedPaneID, pane)
    }

    /// Overview's focused view watches its pane whatever the grid does.
    func testThePaneShownInOverviewStaysSuppressedWhileTheGridIsUp() {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        let pane = PaneID(rawValue: "w2:t1:p1")
        viewModel.update(model: focusedModel(.blocked), connection: .live)
        viewModel.paneShownInOverview = pane
        viewModel.isMainCanvasCovered = true
        XCTAssertTrue(viewModel.attentionToasts.isEmpty, "opening the grid raised the shown pane")
        viewModel.update(model: focusedModel(.working), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: focusedModel(.blocked), connection: .live)
        XCTAssertNil(viewModel.attentionToasts.toast(pane: pane))
    }

    // MARK: - herdr's focus under Overview

    private let left = PaneID(rawValue: "w1:t1:p1")
    private let api = PaneID(rawValue: "w2:t1:p1")
    private let web = PaneID(rawValue: "w2:t2:p1")
    private let openedAPI = ["tab.focus w2:t1", "pane.focus w2:t1:p1"]

    /// home's pane is where Workspaces was left; acme's two tabs hold the
    /// panes Overview opens.
    private func overviewModel(
        left: AgentStatus = .idle, api: AgentStatus = .idle, web: AgentStatus = .idle,
        focused: String = "w1:t1:p1", homeHasPane: Bool = true
    ) -> SessionModel {
        MissionFixture.model([
            .init(label: "home", tabs: [.init(label: "main", panes: homeHasPane ? [.init(status: left)] : [])]),
            .init(label: "acme", tabs: [
                .init(label: "api", panes: [.init(status: api)]), .init(label: "web", panes: [.init(status: web)]),
            ]),
        ], focusedPane: focused)
    }

    /// What `JumpNavigator` and the focused view do between them.
    private func open(_ pane: PaneID, in viewModel: SessionViewModel) async {
        XCTAssertTrue(viewModel.focusInOverview(pane: pane))
        viewModel.paneShownInOverview = pane
        await viewModel.herdrFocusQueue?.value
    }

    func testOpeningAPaneInOverviewFocusesItInHerdr() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        await open(api, in: viewModel)
        let focuses = await client.focuses
        XCTAssertEqual(focuses, openedAPI)
    }

    func testReturningToWorkspacesGivesBackTheFocusItWasLeftWith() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        await open(api, in: viewModel)
        await open(web, in: viewModel)
        viewModel.update(model: overviewModel(focused: "w2:t2:p1"), connection: .live)
        viewModel.select(tab: TabID(rawValue: "w2:t2"))

        viewModel.isMainCanvasCovered = false
        XCTAssertEqual(viewModel.selectedTabID, TabID(rawValue: "w1:t1"), "the canvas's first frame drew Overview's tab")
        XCTAssertEqual(viewModel.selectedWorkspaceID, WorkspaceID(rawValue: "w1"))
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, left)
        viewModel.paneShownInOverview = nil
        await viewModel.herdrFocusQueue?.value
        let focuses = await client.focuses
        XCTAssertEqual(focuses, openedAPI + ["tab.focus w2:t2", "pane.focus w2:t2:p1", "tab.focus w1:t1", "pane.focus w1:t1:p1"])
    }

    func testSwitchingViewsWithoutOpeningAPaneMovesNothing() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        viewModel.isMainCanvasCovered = false
        await viewModel.herdrFocusQueue?.value
        let calls = await client.calls
        XCTAssertEqual(calls, [])
    }

    /// A route that leaves the grid for a pane of its own forgets the focus
    /// before the grid closes; a jump made while the grid is up forgets it too.
    func testALandingOfItsOwnIsNotUndone() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        await open(api, in: viewModel)
        viewModel.forgetWorkspacesFocus()
        viewModel.isMainCanvasCovered = false
        await viewModel.jumpToPane(web)
        await viewModel.herdrFocusQueue?.value
        var focuses = await client.focuses
        XCTAssertEqual(focuses, openedAPI + ["tab.focus w2:t2", "pane.focus w2:t2:p1"])

        let stepped = RecordingClient()
        let steppedModel = SessionViewModel(client: stepped)
        steppedModel.update(model: overviewModel(), connection: .live)
        steppedModel.isMainCanvasCovered = true
        await open(api, in: steppedModel)
        await steppedModel.jumpToHerdr(tab: TabID(rawValue: "w2:t2"))
        steppedModel.isMainCanvasCovered = false
        await steppedModel.herdrFocusQueue?.value
        focuses = await stepped.focuses
        XCTAssertEqual(focuses, openedAPI + ["tab.focus w2:t2"])
    }

    /// rt's focus pane moves herdr while flock is in the background, then
    /// raises flock: the window lands on that pane with nothing given back.
    func testAFocusMovedFromOutsideLandsWithoutAGiveBack() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        await open(api, in: viewModel)
        viewModel.update(model: overviewModel(focused: "w2:t1:p1"), connection: .live)
        XCTAssertEqual(viewModel.externalFocusMoves, 0, "Overview's own move is flock's")

        viewModel.appLeftFront()
        viewModel.update(model: overviewModel(focused: "w2:t2:p1"), connection: .live)
        viewModel.appCameToFront()
        XCTAssertEqual(viewModel.externalFocusMoves, 1)

        viewModel.forgetWorkspacesFocus()
        viewModel.isMainCanvasCovered = false
        await viewModel.herdrFocusQueue?.value
        let focuses = await client.focuses
        XCTAssertEqual(focuses, openedAPI)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, web)
    }

    func testARecordedPaneThatClosedIsNotGivenBack() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        await open(api, in: viewModel)
        viewModel.update(model: overviewModel(focused: "w2:t1:p1", homeHasPane: false), connection: .live)
        viewModel.isMainCanvasCovered = false
        await viewModel.herdrFocusQueue?.value
        let focuses = await client.focuses
        XCTAssertEqual(focuses, openedAPI)
        XCTAssertEqual(viewModel.resolvedFocusedPaneID, api)
    }

    /// The give-back waits a turn for Overview's own moves to go out; a jump
    /// in that turn wins, and the canvas stops predicting the given-back pane.
    func testAJumpRightAfterReturningCancelsTheGiveBack() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.isMainCanvasCovered = true
        await open(api, in: viewModel)
        viewModel.isMainCanvasCovered = false
        XCTAssertEqual(viewModel.optimisticFocusedPaneID, left)
        await viewModel.jumpToHerdr(workspace: WorkspaceID(rawValue: "w2"))
        await viewModel.herdrFocusQueue?.value
        let focuses = await client.focuses
        XCTAssertEqual(focuses, openedAPI + ["workspace.focus w2"])
        XCTAssertNil(viewModel.optimisticFocusedPaneID)
    }

    /// The rt coordinator reads the same mark through `leavesFocusAlone`; a
    /// pane marked shown while the main canvas is on screen moves nothing.
    func testShowingAPaneOverAnUncoveredCanvasMovesNothing() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: overviewModel(), connection: .live)
        viewModel.paneShownInOverview = api
        XCTAssertTrue(viewModel.rt.leavesFocusAlone())
        XCTAssertNil(viewModel.herdrFocusQueue)
        let calls = await client.calls
        XCTAssertEqual(calls, [])
    }

    /// Opening `api` and giving the focus back neither raises nor dismisses
    /// any card but `api`'s own, including while herdr's echo still names
    /// `api` after the canvas is back.
    func testFocusMovesUnderOverviewTouchNoOtherCard() async {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.update(model: overviewModel(api: .working, web: .working), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: overviewModel(left: .blocked, api: .working, web: .working), connection: .live)
        XCTAssertTrue(viewModel.attentionToasts.isEmpty)
        viewModel.isMainCanvasCovered = true
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: overviewModel(left: .blocked, api: .done, web: .done), connection: .live)
        XCTAssertEqual(viewModel.attentionToasts.toasts.count, 3)

        await open(api, in: viewModel)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: overviewModel(left: .blocked, web: .done, focused: "w2:t1:p1"), connection: .live)
        viewModel.isMainCanvasCovered = false
        viewModel.paneShownInOverview = nil
        viewModel.update(model: overviewModel(left: .blocked, web: .done, focused: "w2:t1:p1"), connection: .live)
        await viewModel.herdrFocusQueue?.value
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: overviewModel(left: .blocked, web: .done), connection: .live)
        viewModel.sweepAttentionToasts()

        XCTAssertEqual(Set(viewModel.attentionToasts.toasts.map(\.paneID)), [left, web])
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: left)?.kind, .needsInput, "a look is not an answer")
        XCTAssertEqual(viewModel.attentionToasts.toast(pane: web)?.kind, .finished)
    }
}
