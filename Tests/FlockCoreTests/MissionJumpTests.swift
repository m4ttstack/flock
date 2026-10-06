import XCTest
@testable import FlockCore

private actor RecordingClient: HerdrCommandClient {
    private(set) var calls: [String] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append(method)
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

    func testFocusingInOverviewDismissesTheCardAndNeverMovesHerdr() async {
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
        XCTAssertEqual(calls, [], "focusing in Overview sends herdr nothing")
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
}
