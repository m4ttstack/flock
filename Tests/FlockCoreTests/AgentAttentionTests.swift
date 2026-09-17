import XCTest
@testable import FlockCore

/// herdr's attention order, and the tab/workspace status flock has to
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

    /// Closing the one pane that was asking has to take the tab's and the
    /// workspace's red away with it. herdr recomputes on every TabInfo and
    /// WorkspaceInfo it builds, so a rail dot left red here disagrees with
    /// the TUI sitting next to it until the next status event.
    func testClosingThePaneThatWasBlockedTakesItsTabAndWorkspaceDown() throws {
        var model = try seededModel()
        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .blocked), to: &model)
        XCTAssertEqual(model.workspaces.first?.agentStatus, .blocked)

        apply(.paneClosed(PaneID(rawValue: "w1:p2")), to: &model)

        XCTAssertEqual(model.tabs[WorkspaceID(rawValue: "w1")]?.first { $0.tabID == TabID(rawValue: "w1:t1") }?.agentStatus, .unknown)
        XCTAssertEqual(model.workspaces.first?.agentStatus, .unknown)
    }

    /// A move is two aggregates, not one: the tab it left and the tab it
    /// arrived in.
    func testMovingABlockedPaneMovesTheStatusToItsNewTab() throws {
        var model = try seededModel()
        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .blocked), to: &model)

        let moved = PaneRecord(
            paneID: PaneID(rawValue: "w1:p2"), workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:t2"), focused: false, agentStatus: .blocked, revision: 1,
            terminalTitleStripped: nil, label: nil, cwd: "/private/tmp", scroll: nil
        )
        apply(.paneMoved(PaneMovedPayload(
            previousPaneID: PaneID(rawValue: "w1:p2"), previousWorkspaceID: WorkspaceID(rawValue: "w1"),
            previousTabID: TabID(rawValue: "w1:t1"), pane: moved, createdTab: nil, createdWorkspace: nil,
            closedTabID: nil, closedWorkspaceID: nil
        )), to: &model)

        let tabs = model.tabs[WorkspaceID(rawValue: "w1")]
        XCTAssertEqual(tabs?.first { $0.tabID == TabID(rawValue: "w1:t1") }?.agentStatus, .unknown, "the tab it left")
        XCTAssertEqual(tabs?.first { $0.tabID == TabID(rawValue: "w1:t2") }?.agentStatus, .blocked, "the tab it joined")
        XCTAssertEqual(model.workspaces.first?.agentStatus, .blocked, "it never left the workspace")
    }

    func testAgentStatusChangeForAPaneTheModelDoesNotCarryIsANoOp() throws {
        var model = try seededModel()
        let before = model

        apply(.paneAgentStatusChanged(PaneID(rawValue: "w9:p9"), .blocked), to: &model)

        XCTAssertEqual(model, before)
    }
}
