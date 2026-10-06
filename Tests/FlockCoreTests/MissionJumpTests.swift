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

    func testJumpingToAPaneFocusesItAndRemembersTheOrigin() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: model([.working]), connection: .live)
        await viewModel.jumpToPane(PaneID(rawValue: "w2:t1:p1"), from: .missionControl)
        let calls = await client.calls
        XCTAssertEqual(calls, ["tab.focus", "pane.focus"])
        XCTAssertEqual(viewModel.jumpBackTarget(from: .pane(PaneID(rawValue: "w2:t1:p1"))), .missionControl)
    }

    func testInMissionControlTheKeyOpensTheOldestCardOfAllNotTheOldestTheDockDraws() async {
        let clock = Clock()
        let viewModel = SessionViewModel(client: RecordingClient(), now: { clock.now })
        viewModel.attentionCardLimit = 1
        viewModel.update(model: model([.working, .working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked, .working]), connection: .live)
        clock.now = clock.now.addingTimeInterval(10)
        viewModel.update(model: model([.blocked, .blocked]), connection: .live)
        await viewModel.jumpToOldestAttentionToast(from: .missionControl)
        XCTAssertNil(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p1")), "the oldest card was taken")
        XCTAssertNotNil(viewModel.attentionToasts.toast(pane: PaneID(rawValue: "w2:t1:p2")))
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

    func testAClosedOriginOffersNoWayBack() async {
        let viewModel = SessionViewModel(client: RecordingClient())
        viewModel.update(model: model([.working, .idle]), connection: .live)
        await viewModel.jumpToPane(PaneID(rawValue: "w2:t1:p1"), from: .pane(PaneID(rawValue: "w2:t1:p2")))
        viewModel.update(model: model([.working]), connection: .live)
        XCTAssertNil(viewModel.jumpBackTarget(from: .pane(PaneID(rawValue: "w2:t1:p1"))))
    }

    /// Jump A to B, click back to A by hand: Jump Back is off rather than a
    /// jump from A to A that records A and then does nothing for good.
    func testJumpBackIsOffWhereItWouldLand() async {
        let viewModel = SessionViewModel(client: RecordingClient())
        viewModel.update(model: model([.working, .idle]), connection: .live)
        let a = PaneID(rawValue: "w2:t1:p2")
        let b = PaneID(rawValue: "w2:t1:p1")
        await viewModel.jumpToPane(b, from: .pane(a))
        XCTAssertEqual(viewModel.jumpBackTarget(from: .pane(b)), .pane(a))
        XCTAssertNil(viewModel.jumpBackTarget(from: .pane(a)), "already at the origin")
        await viewModel.jumpToPane(a, from: .pane(a))
        XCTAssertEqual(viewModel.jumpBackTarget(from: .pane(b)), .pane(a), "a jump to where it started records nothing")
    }
}
