import XCTest
@testable import FlockCore

/// `workspaces` is each workspace's id paired with its tab ids in rail and
/// strip order; the first tab of each is its active one, which is what a
/// landing on a workspace row has to pick up.
private func makeModel(_ workspaces: [(String, [String])]) -> SessionModel {
    let workspaceJSON = workspaces.enumerated().map { index, entry in
        #"{"workspace_id":"\#(entry.0)","label":"\#(entry.0)","number":\#(index + 1),"active_tab_id":"\#(entry.1[0])","agent_status":"unknown"}"#
    }
    let tabJSON = workspaces.flatMap { entry in
        entry.1.enumerated().map { index, tab in
            #"{"tab_id":"\#(tab)","workspace_id":"\#(entry.0)","label":"\#(index + 1)","number":\#(index + 1),"pane_count":1,"agent_status":"unknown"}"#
        }
    }
    let snapshotJSON = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(workspaces[0].0)","focused_tab_id":"\#(workspaces[0].1[0])","focused_pane_id":null,"workspaces":[\#(workspaceJSON.joined(separator: ","))],"tabs":[\#(tabJSON.joined(separator: ","))],"panes":[],"layouts":[]}
    """#
    let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
    return SessionModel(snapshot: snapshot)
}

private func selection(workspace: String?, tab: String?) -> CloseSelection.Selection {
    CloseSelection.Selection(
        workspace: workspace.map { WorkspaceID(rawValue: $0) },
        tab: tab.map { TabID(rawValue: $0) }
    )
}

final class CloseSelectionTests: XCTestCase {
    /// herdr's `Workspace::close_tab` decrements `active_tab` when the closed
    /// tab sat at or before it, so the tab on the left is what a closed
    /// middle tab hands selection to.
    func testAClosedTabHandsSelectionToTheTabOnItsLeft() {
        let before = makeModel([("w1", ["w1:t1", "w1:t2", "w1:t3"])])
        let after = makeModel([("w1", ["w1:t1", "w1:t3"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t2"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w1", tab: "w1:t1"))
    }

    /// The one tab with nothing on its left. herdr's decrement is guarded on
    /// `active_tab > 0`, so index 0 stays index 0 and the tab that slides into
    /// it is the one on the right.
    func testTheLeftmostTabHandsSelectionRightward() {
        let before = makeModel([("w1", ["w1:t1", "w1:t2", "w1:t3"])])
        let after = makeModel([("w1", ["w1:t2", "w1:t3"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t1"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w1", tab: "w1:t2"))
    }

    func testTheRightmostTabHandsSelectionLeftward() {
        let before = makeModel([("w1", ["w1:t1", "w1:t2", "w1:t3"])])
        let after = makeModel([("w1", ["w1:t1", "w1:t2"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t3"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w1", tab: "w1:t2"))
    }

    /// Closing a tab nobody was sitting on moves nothing: herdr's own
    /// decrement keeps the same tab active across it.
    func testClosingAnotherTabLeavesTheSelectionWhereItIs() {
        let before = makeModel([("w1", ["w1:t1", "w1:t2", "w1:t3"])])
        let after = makeModel([("w1", ["w1:t2", "w1:t3"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t2"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w1", tab: "w1:t2"))
    }

    /// `App::close_selected_workspace` keeps the closed workspace's own index,
    /// so the row that slides up into it, the one below, is what takes over --
    /// the opposite direction to the tab rule, and deliberately so.
    func testAClosedWorkspaceHandsSelectionToTheRowBelow() {
        let before = makeModel([("w1", ["w1:t1"]), ("w2", ["w2:t1"]), ("w3", ["w3:t1"])])
        let after = makeModel([("w1", ["w1:t1"]), ("w3", ["w3:t1"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w2", tab: "w2:t1"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w3", tab: "w3:t1"), "and on that workspace's own active tab")
    }

    /// The clamp to `workspaces.len() - 1`: the last row has nothing below it.
    func testTheLastWorkspaceRowHandsSelectionUpward() {
        let before = makeModel([("w1", ["w1:t1"]), ("w2", ["w2:t1"]), ("w3", ["w3:t1"])])
        let after = makeModel([("w1", ["w1:t1"]), ("w2", ["w2:t1"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w3", tab: "w3:t1"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w2", tab: "w2:t1"))
    }

    /// herdr's `active = None` when the last workspace goes. flock has to be
    /// able to say the same, rather than hold a dead id.
    func testClosingTheOnlyWorkspaceLeavesNothingSelected() {
        let before = makeModel([("w1", ["w1:t1"])])
        var after = before
        after.workspaces = []
        after.tabs = [:]

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t1"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: nil, tab: nil))
    }

    /// flock's own selection can name a tab herdr has not reported yet (the
    /// window picks one before the snapshot describing it arrives). Absent
    /// from both models is not a close, and treating it as one would land the
    /// user somewhere they never asked to be.
    func testATabNeitherModelCarriesIsNotAClose() {
        let model = makeModel([("w1", ["w1:t1", "w1:t2"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t9"), before: model, after: model)

        XCTAssertEqual(landing, selection(workspace: "w1", tab: "w1:t9"))
    }

    /// Several events can land in one update. The neighbor herdr's own
    /// single-step rule names may itself be gone by then, so the walk
    /// continues in the same direction rather than stopping on a dead id.
    func testABurstThatTakesTheNeighborTooKeepsWalkingTheSameWay() {
        let before = makeModel([("w1", ["w1:t1", "w1:t2", "w1:t3", "w1:t4"])])
        let after = makeModel([("w1", ["w1:t1", "w1:t4"])])

        let landing = CloseSelection.landing(for: selection(workspace: "w1", tab: "w1:t3"), before: before, after: after)

        XCTAssertEqual(landing, selection(workspace: "w1", tab: "w1:t1"))
    }
}
