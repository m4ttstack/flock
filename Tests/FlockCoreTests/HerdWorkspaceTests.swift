import XCTest
@testable import FlockCore

private func model(workspaceLabel: String) -> SessionModel {
    let json = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1",
     "workspaces":[{"workspace_id":"w1","label":"flock","number":1,"active_tab_id":"w1:t1","agent_status":"idle"},
                   {"workspace_id":"w2","label":"\#(workspaceLabel)","number":2,"active_tab_id":"w2:t1","agent_status":"idle"}],
     "tabs":[{"tab_id":"w2:t1","workspace_id":"w2","label":"migrate","number":1,"pane_count":1,"agent_status":"idle"}],
     "panes":[{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"idle","revision":0,"cwd":"/tmp","label":"migrate"},
              {"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","focused":false,"agent_status":"idle","revision":0,"cwd":"/tmp","label":"orphan"}],
     "layouts":[]}
    """#
    return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
}

final class HerdWorkspaceTests: XCTestCase {
    func testTheLabelRtMintsForAHerdIsRecognised() {
        XCTAssertTrue(HerdWorkspace.isHerd(label: "herd: docs-sweep-20260922-112541"))
        XCTAssertTrue(HerdWorkspace.isHerd(label: "herd: tidy-marks-20260922-093843-2"))
    }

    func testAnOrdinaryWorkspaceLabelIsNotAHerd() {
        XCTAssertFalse(HerdWorkspace.isHerd(label: "repo-tools"))
        XCTAssertFalse(HerdWorkspace.isHerd(label: "acme 🧙🏽‍♂️"))
        XCTAssertFalse(HerdWorkspace.isHerd(label: ""))
    }

    /// The prefix has to lead and has to be followed by an id: a workspace
    /// somebody named "herding cats" is theirs, and a bare "herd: " names no
    /// run at all.
    func testTheSignalIsALeadingPrefixWithAnIdBehindIt() {
        XCTAssertFalse(HerdWorkspace.isHerd(label: "herding cats"))
        XCTAssertFalse(HerdWorkspace.isHerd(label: "shepherd: nightly"))
        XCTAssertFalse(HerdWorkspace.isHerd(label: "herd:"))
        XCTAssertFalse(HerdWorkspace.isHerd(label: "herd: "))
    }

    func testAPaneIsInAHerdWhenTheWorkspaceHoldingItIsOne() {
        let pane = model(workspaceLabel: "herd: nightly-20260922-090000").panes[PaneID(rawValue: "w2:p1")]!
        XCTAssertTrue(HerdWorkspace.isHerdPane(pane, in: model(workspaceLabel: "herd: nightly-20260922-090000")))
        XCTAssertFalse(HerdWorkspace.isHerdPane(pane, in: model(workspaceLabel: "repo-tools")))
    }

    /// A pane whose workspace is missing from the snapshot cannot be shown to
    /// be herd-run, and an unproven claim must not silence a toast.
    func testAPaneWhoseWorkspaceIsUnknownIsNotTreatedAsHerdRun() {
        let orphan = model(workspaceLabel: "herd: nightly-20260922-090000").panes[PaneID(rawValue: "w9:p1")]!
        XCTAssertFalse(HerdWorkspace.isHerdPane(orphan, in: model(workspaceLabel: "herd: nightly-20260922-090000")))
    }
}
