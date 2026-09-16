import XCTest
@testable import PaddockCore

/// herdr's attention order, and the tab/workspace status paddock has to
/// re-derive from it because a live frame only ever names one pane.
final class AgentAttentionTests: XCTestCase {
    /// Not the declaration order of `AgentStatus` (idle, working, blocked,
    /// done, unknown) and not alphabetical: the loudest wins.
    func testAggregateTakesTheLoudestStatus() {
        XCTAssertEqual(AgentAttention.aggregate([.idle, .working, .blocked, .done, .unknown]), .blocked)
        XCTAssertEqual(AgentAttention.aggregate([.idle, .working, .done, .unknown]), .done)
        XCTAssertEqual(AgentAttention.aggregate([.idle, .working, .unknown]), .working)
        XCTAssertEqual(AgentAttention.aggregate([.idle, .unknown]), .idle)
        XCTAssertEqual(AgentAttention.aggregate([.unknown]), .unknown)
    }

    func testAggregateOfNothingIsUnknown() {
        XCTAssertEqual(AgentAttention.aggregate([AgentStatus]()), .unknown)
    }

    /// The seed fixture is one workspace, tab `w1:t1` holding `w1:p1` and
    /// `w1:p2`, tab `w1:t2` holding `w1:p3`; everything starts `unknown`.
    private func seededModel() throws -> SessionModel {
        SessionModel(snapshot: try HerdrDecoder.snapshot(fromResponseLine: try fixture("snapshot.json")))
    }

    func testAgentStatusChangeMovesThePaneAndReDerivesItsTabAndWorkspace() throws {
        var model = try seededModel()

        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .blocked), to: &model)

        XCTAssertEqual(model.panes[PaneID(rawValue: "w1:p2")]?.agentStatus, .blocked)
        XCTAssertEqual(model.panes[PaneID(rawValue: "w1:p1")]?.agentStatus, .unknown)
        XCTAssertEqual(model.tabs[WorkspaceID(rawValue: "w1")]?.first { $0.tabID == TabID(rawValue: "w1:t1") }?.agentStatus, .blocked)
        XCTAssertEqual(model.workspaces.first?.agentStatus, .blocked)
    }

    /// The other tab aggregates only its own panes, so a pane going blocked
    /// in `w1:t1` must leave `w1:t2` exactly where it was.
    func testAgentStatusChangeLeavesAnotherTabAlone() throws {
        var model = try seededModel()

        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .blocked), to: &model)

        XCTAssertEqual(model.tabs[WorkspaceID(rawValue: "w1")]?.first { $0.tabID == TabID(rawValue: "w1:t2") }?.agentStatus, .unknown)
    }

    /// The aggregate is re-derived, not raised: a pane that calms down has to
    /// take its tab and workspace back down with it, or the rail keeps
    /// showing red for an agent that answered ten minutes ago.
    func testAggregateFallsBackWhenThePaneCalmsDown() throws {
        var model = try seededModel()
        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .blocked), to: &model)

        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .idle), to: &model)

        XCTAssertEqual(model.tabs[WorkspaceID(rawValue: "w1")]?.first { $0.tabID == TabID(rawValue: "w1:t1") }?.agentStatus, .idle)
        XCTAssertEqual(model.workspaces.first?.agentStatus, .idle)
    }

    func testAgentStatusChangeForAPaneTheModelDoesNotCarryIsANoOp() throws {
        var model = try seededModel()
        let before = model

        apply(.paneAgentStatusChanged(PaneID(rawValue: "w9:p9"), .blocked), to: &model)

        XCTAssertEqual(model, before)
    }
}
