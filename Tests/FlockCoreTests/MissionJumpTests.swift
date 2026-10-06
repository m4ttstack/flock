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
        XCTAssertEqual(viewModel.jumpBackTarget, .missionControl)
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

    func testAClosedOriginOffersNoWayBack() async {
        let viewModel = SessionViewModel(client: RecordingClient())
        viewModel.update(model: model([.working, .idle]), connection: .live)
        await viewModel.jumpToPane(PaneID(rawValue: "w2:t1:p1"), from: .pane(PaneID(rawValue: "w2:t1:p2")))
        viewModel.update(model: model([.working]), connection: .live)
        XCTAssertNil(viewModel.jumpBackTarget)
    }
}
