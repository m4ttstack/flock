import XCTest
@testable import FlockCore

private actor FooterReadClient: HerdrCommandClient {
    struct Ask: Equatable {
        let pane: String
        /// The params as sorted JSON.
        let params: String
    }

    private(set) var asks: [Ask] = []
    private var screens: [String: String]
    private var failing: Set<String> = []

    init(screens: [String: String]) {
        self.screens = screens
    }

    func set(_ pane: String, screen: String) { screens[pane] = screen }
    func fail(_ pane: String) { failing.insert(pane) }

    func reads(of pane: String) -> Int { asks.count { $0.pane == pane } }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read", case .string(let pane) = params["pane_id"] else { return Data("{}".utf8) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        asks.append(Ask(pane: pane, params: String(decoding: try encoder.encode(params), as: UTF8.self)))
        if failing.contains(pane) { return Data("{}".utf8) }
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": screens[pane] ?? ""]]])
    }
}

@MainActor
final class SessionViewModelBackgroundWorkTests: XCTestCase {
    private let p1 = PaneID(rawValue: "w1:t1:p1")
    private let p2 = PaneID(rawValue: "w1:t1:p2")

    private struct TimedOut: Error {}

    private func model(_ statuses: [AgentStatus], agents: [String?]) -> SessionModel {
        var model = MissionFixture.single(statuses)
        for (index, agent) in agents.enumerated() {
            model.panes[PaneID(rawValue: "w1:t1:p\(index + 1)")]?.agent = agent
        }
        return model
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never: \(what)")
        throw TimedOut()
    }

    func testAnIdleClaudePaneIsReadAsPlainVisibleText() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .seconds(60))
        viewModel.update(model: model([.idle], agents: ["claude"]), connection: .live)
        try await eventually("the reason lands") { viewModel.backgroundWork[p1] == "1 shell" }
        let asks = await client.asks
        XCTAssertEqual(asks.map(\.params), [#"{"format":"text","pane_id":"w1:t1:p1","source":"visible"}"#])
        let pane = try XCTUnwrap(viewModel.model?.panes[p1])
        XCTAssertEqual(viewModel.shownStatus(of: pane), ShownStatus(.idle, backgroundWork: "1 shell"))
    }

    func testOnlyClaudePanesBetweenTurnsAreRead() async throws {
        let screens = Dictionary(uniqueKeysWithValues: (1...5).map { ("w1:t1:p\($0)", FooterFixture.shell) })
        let client = FooterReadClient(screens: screens)
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .seconds(60))
        viewModel.update(
            model: model([.done, .working, .blocked, .idle, .idle], agents: ["claude", "claude", "claude", "codex", nil]),
            connection: .live
        )
        try await eventually("the done pane is read") { viewModel.backgroundWork[p1] != nil }
        try await Task.sleep(for: .milliseconds(30))
        let read = Set(await client.asks.map(\.pane))
        XCTAssertEqual(read, ["w1:t1:p1"])
        XCTAssertEqual(Array(viewModel.backgroundWork.keys), [p1])
    }

    func testNothingIsReadWhileDisconnected() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .milliseconds(10))
        viewModel.update(model: model([.idle], agents: ["claude"]), connection: .reconnecting(attempt: 1))
        try await Task.sleep(for: .milliseconds(60))
        let reads = await client.reads(of: "w1:t1:p1")
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(viewModel.backgroundWork.isEmpty)
    }

    func testTheCadenceReadsAgainAndPicksUpTheFooterClearing() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .milliseconds(10))
        viewModel.update(model: model([.idle], agents: ["claude"]), connection: .live)
        try await eventually("the shell is seen") { viewModel.backgroundWork[p1] == "1 shell" }
        await client.set("w1:t1:p1", screen: FooterFixture.shellAndMonitor)
        try await eventually("the monitor is seen") { viewModel.backgroundWork[p1] == "1 shell, 1 monitor" }
        await client.set("w1:t1:p1", screen: FooterFixture.plain)
        try await eventually("a footer with no count clears the entry") { viewModel.backgroundWork[p1] == nil }
    }

    func testAFailedReadKeepsTheLastAnswer() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .milliseconds(10))
        viewModel.update(model: model([.idle], agents: ["claude"]), connection: .live)
        try await eventually("the shell is seen") { viewModel.backgroundWork[p1] == "1 shell" }
        await client.fail("w1:t1:p1")
        let before = await client.reads(of: "w1:t1:p1")
        try await eventually("two more reads fail") { await client.reads(of: "w1:t1:p1") >= before + 2 }
        XCTAssertEqual(viewModel.backgroundWork[p1], "1 shell")
    }

    func testAPaneThatStartsWorkingIsForgottenAndNoLongerRead() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell, "w1:t1:p2": FooterFixture.monitors])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .milliseconds(10))
        viewModel.update(model: model([.idle, .idle], agents: ["claude", "claude"]), connection: .live)
        try await eventually("both are seen") { viewModel.backgroundWork.count == 2 }
        viewModel.update(model: model([.working, .idle], agents: ["claude", "claude"]), connection: .live)
        XCTAssertNil(viewModel.backgroundWork[p1], "cleared at once, not at the next read")
        XCTAssertEqual(viewModel.backgroundWork[p2], "2 monitors")
        try await Task.sleep(for: .milliseconds(20))
        let settled = await client.reads(of: "w1:t1:p1")
        try await eventually("the other pane is still read") { await client.reads(of: "w1:t1:p2") >= 4 }
        let after = await client.reads(of: "w1:t1:p1")
        XCTAssertEqual(after, settled, "a working pane is not read")
    }

    func testAPaneThatClosesOrADroppedConnectionClearsEverything() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell, "w1:t1:p2": FooterFixture.monitors])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .milliseconds(10))
        viewModel.update(model: model([.idle, .idle], agents: ["claude", "claude"]), connection: .live)
        try await eventually("both are seen") { viewModel.backgroundWork.count == 2 }
        viewModel.update(model: model([.idle], agents: ["claude"]), connection: .live)
        XCTAssertEqual(Array(viewModel.backgroundWork.keys), [p1])
        viewModel.update(model: nil, connection: .reconnecting(attempt: 1))
        XCTAssertTrue(viewModel.backgroundWork.isEmpty)
        try await Task.sleep(for: .milliseconds(20))
        let settled = await client.asks.count
        try await Task.sleep(for: .milliseconds(50))
        let after = await client.asks.count
        XCTAssertEqual(after, settled, "the cadence stopped with the connection")
    }

    func testAWorkspaceAndTabShowBackgroundWorkFromTheirPanes() async throws {
        let client = FooterReadClient(screens: ["w1:t1:p1": FooterFixture.shell])
        let viewModel = SessionViewModel(client: client, backgroundWorkInterval: .seconds(60))
        viewModel.update(model: model([.idle, .idle], agents: ["claude", nil]), connection: .live)
        try await eventually("the shell is seen") { viewModel.backgroundWork[p1] != nil }
        let workspace = try XCTUnwrap(viewModel.model?.workspaces.first)
        let tab = try XCTUnwrap(viewModel.model?.tabs[workspace.workspaceID]?.first)
        XCTAssertTrue(viewModel.shownStatus(of: workspace).isBackground)
        XCTAssertTrue(viewModel.shownStatus(of: tab).isBackground)
    }
}
