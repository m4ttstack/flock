import XCTest
@testable import FlockCore

final class VisibleSessionTests: XCTestCase {
    private func model(focusedWorkspace: String, focusedTab: String, focusedPane: String) -> SessionModel {
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"\#(focusedWorkspace)","focused_tab_id":"\#(focusedTab)","focused_pane_id":"\#(focusedPane)",
         "workspaces":[{"workspace_id":"w1","label":"acme","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},
                       {"workspace_id":"wF","label":"flock:rt","number":2,"active_tab_id":"wF:t1","agent_status":"unknown"},
                       {"workspace_id":"wR","label":"flock:rt runner term_a1","number":3,"active_tab_id":"wR:t1","agent_status":"unknown"}],
         "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"main","number":1,"pane_count":1,"agent_status":"unknown"},
                 {"tab_id":"wF:t1","workspace_id":"wF","label":"nav term_a1 tok1","number":1,"pane_count":1,"agent_status":"unknown"},
                 {"tab_id":"wR:t1","workspace_id":"wR","label":"runner term_a1 tok2","number":1,"pane_count":1,"agent_status":"unknown"}],
         "panes":[{"pane_id":"w1:p1","terminal_id":"term_a1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"},
                  {"pane_id":"wF:p1","terminal_id":"term_f1","workspace_id":"wF","tab_id":"wF:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"},
                  {"pane_id":"wR:p1","terminal_id":"term_r1","workspace_id":"wR","tab_id":"wR:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/src/acme"}],
         "layouts":[{"workspace_id":"wF","tab_id":"wF:t1","zoomed":false,"area":{"x":0,"y":0,"width":80,"height":24},"focused_pane_id":"wF:p1","panes":[{"pane_id":"wF:p1","focused":true,"rect":{"x":0,"y":0,"width":80,"height":24}}],"splits":[]}]}
        """#
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    func testFlockOwnedWorkspacesAndEverythingInThemAreGone() {
        let visible = model(focusedWorkspace: "w1", focusedTab: "w1:t1", focusedPane: "w1:p1").withoutFlockOwned

        XCTAssertEqual(visible.workspaces.map(\.workspaceID), [WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(Set(visible.tabs.keys), [WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(Set(visible.panes.keys), [PaneID(rawValue: "w1:p1")])
        XCTAssertTrue(visible.layouts.isEmpty)
        XCTAssertEqual(visible.focusedTabID, TabID(rawValue: "w1:t1"))
    }

    /// herdr's focus inside a hidden workspace reads as no focus at all, so
    /// nothing that follows focus can follow it there.
    func testFocusInsideAFlockOwnedWorkspaceReadsAsNone() {
        let visible = model(focusedWorkspace: "wR", focusedTab: "wR:t1", focusedPane: "wR:p1").withoutFlockOwned

        XCTAssertNil(visible.focusedWorkspaceID)
        XCTAssertNil(visible.focusedTabID)
        XCTAssertNil(visible.focusedPaneID)
    }
}
