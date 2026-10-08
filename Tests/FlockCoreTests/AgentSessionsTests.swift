import XCTest
@testable import FlockCore

/// `tabs` is each tab's id paired with its panes, each pane an id and the
/// agent herdr detected in it, nil for a shell. Every pane is idle, so no
/// busy count can be what raises a prompt.
private func makeModel(tabs: [(String, [(String, String?)])]) -> SessionModel {
    let tabJSON = tabs.enumerated().map { index, entry in
        #"{"tab_id":"\#(entry.0)","workspace_id":"w1","label":"\#(index + 1)","number":\#(index + 1),"pane_count":\#(entry.1.count),"agent_status":"idle"}"#
    }
    let paneJSON = tabs.flatMap { entry in
        entry.1.map { pane in
            let agent = pane.1.map { #","agent":"\#($0)""# } ?? ""
            return #"{"pane_id":"\#(pane.0)","workspace_id":"w1","tab_id":"\#(entry.0)","focused":false,"agent_status":"idle","revision":0,"cwd":"/tmp"\#(agent)}"#
        }
    }
    let snapshotJSON = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"\#(tabs[0].0)","focused_pane_id":null,"workspaces":[{"workspace_id":"w1","label":"seed","number":4,"active_tab_id":"\#(tabs[0].0)","agent_status":"idle"}],"tabs":[\#(tabJSON.joined(separator: ","))],"panes":[\#(paneJSON.joined(separator: ","))],"layouts":[]}
    """#
    let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
    return SessionModel(snapshot: snapshot)
}

private actor OfflineCommandClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}

private final class RecordingPlanExecutor: PlanExecuting {
    private(set) var executedPlans: [OpPlan] = []

    func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        executedPlans.append(plan)
        return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: [], label: "Undo \(plan.label)")))
    }
}

/// A close that ends an agent's session asks first even when the agent is
/// idle: the conversation is the loss, not work in flight.
final class AgentSessionsTests: XCTestCase {
    /// Two tabs, so neither close escalates.
    private func twoTabModel(_ p1: String?, _ p2: String?, _ p3: String? = nil) -> SessionModel {
        makeModel(tabs: [("w1:t1", [("w1:p1", p1), ("w1:p2", p2)]), ("w1:t2", [("w1:p3", p3)])])
    }

    private func confirmation(closing subject: CloseSubject, in model: SessionModel) -> CloseConfirmation? {
        let consequence = CloseConsequence.of(subject, model: model)
        return consequence.confirmation(
            closing: subject,
            busy: BusyPanes(closing: subject, consequence: consequence, model: model),
            agents: AgentSessions(closing: subject, consequence: consequence, model: model)
        )
    }

    func testClosingATabWithAnIdleClaudeAsks() throws {
        let model = twoTabModel("claude", nil)

        let prompt = try XCTUnwrap(confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model))

        XCTAssertTrue(prompt.warnsOfAgents)
        XCTAssertEqual(prompt.title, "Close this tab?")
        XCTAssertEqual(prompt.message, "The close ends a Claude Code session. A close cannot be undone.")
    }

    func testABareTerminalClosesWithoutAsking() {
        let model = twoTabModel(nil, nil)

        XCTAssertNil(confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model))
        XCTAssertNil(confirmation(closing: .pane(PaneID(rawValue: "w1:p1")), in: model))
    }

    /// The sibling keeps running, so its session is not the close's to end.
    func testAPaneCloseWeighsOnlyThatPane() {
        let model = twoTabModel(nil, "claude")

        XCTAssertNil(confirmation(closing: .pane(PaneID(rawValue: "w1:p1")), in: model))
        XCTAssertEqual(
            confirmation(closing: .pane(PaneID(rawValue: "w1:p2")), in: model)?.message,
            "The close ends a Claude Code session. A close cannot be undone."
        )
    }

    func testOneAgentTwiceIsCountedByName() {
        let model = twoTabModel("codex", "codex")

        XCTAssertEqual(
            confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model)?.message,
            "The close ends 2 Codex sessions. A close cannot be undone."
        )
    }

    func testMixedAgentsAreCountedAsAgentSessions() {
        let model = twoTabModel("claude", "codex")

        XCTAssertEqual(
            confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model)?.message,
            "The close ends 2 agent sessions. A close cannot be undone."
        )
    }

    /// Any agent herdr detects counts, under the name herdr gives it.
    func testAnUnnamedAgentIsCalledByHerdrsName() {
        let model = twoTabModel("gemini", nil)

        XCTAssertEqual(
            confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model)?.message,
            "The close ends a Gemini session. A close cannot be undone."
        )
    }

    /// A last-tab close asks anyway; the agent line joins that prompt.
    func testTheAgentLineJoinsAnEscalationPrompt() throws {
        let model = makeModel(tabs: [("w1:t1", [("w1:p1", "claude")])])

        let prompt = try XCTUnwrap(confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model))

        XCTAssertTrue(prompt.warnsOfAgents)
        XCTAssertEqual(prompt.confirmButtonTitle, "Close Workspace")
        XCTAssertTrue(prompt.message.contains("The close ends a Claude Code session."), prompt.message)
    }

    func testAnEscalationWithoutAnAgentCarriesNoWarning() throws {
        let model = makeModel(tabs: [("w1:t1", [("w1:p1", nil)])])

        let prompt = try XCTUnwrap(confirmation(closing: .tab(TabID(rawValue: "w1:t1")), in: model))

        XCTAssertFalse(prompt.warnsOfAgents)
    }

    // MARK: - The view model and the setting

    @MainActor
    private func viewModel(warning: Bool) throws -> (SessionViewModel, RecordingPlanExecutor, AgentCloseWarningStore) {
        let suite = "AgentSessionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = AgentCloseWarningStore(userDefaults: defaults)
        store.select(warning)
        let executor = RecordingPlanExecutor()
        let viewModel = SessionViewModel(client: OfflineCommandClient(), planExecutor: executor, agentCloseWarning: store)
        viewModel.update(model: twoTabModel("claude", nil), connection: .live)
        return (viewModel, executor, store)
    }

    @MainActor
    func testClosingAnAgentsTabAsksBeforeSendingAnything() async throws {
        let (viewModel, executor, _) = try viewModel(warning: true)

        await viewModel.closeTab(TabID(rawValue: "w1:t1"))

        XCTAssertTrue(executor.executedPlans.isEmpty)
        XCTAssertEqual(viewModel.pendingClose?.warnsOfAgents, true)
    }

    @MainActor
    func testWithTheWarningOffAnAgentsTabClosesAtOnce() async throws {
        let (viewModel, executor, _) = try viewModel(warning: false)

        await viewModel.closeTab(TabID(rawValue: "w1:t1"))

        XCTAssertNil(viewModel.pendingClose)
        XCTAssertEqual(executor.executedPlans, [OpPlan(ops: [.closeTab(TabID(rawValue: "w1:t1"))], label: "Close tab")])
    }

    @MainActor
    func testDontWarnMeNextTimeTurnsTheSettingOff() throws {
        let (viewModel, _, store) = try viewModel(warning: true)

        viewModel.stopWarningOnAgentCloses()

        XCTAssertFalse(store.active)
    }

    @MainActor
    func testTheWarningIsOnByDefaultAndRemembered() throws {
        let suite = "AgentSessionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(AgentCloseWarningStore(userDefaults: defaults).active)
        AgentCloseWarningStore(userDefaults: defaults).select(false)
        XCTAssertFalse(AgentCloseWarningStore(userDefaults: defaults).active)
    }
}
