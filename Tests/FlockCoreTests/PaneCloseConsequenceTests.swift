import XCTest
@testable import FlockCore

/// `tabs` is each tab's id paired with the panes it holds, in strip order;
/// `label` defaults to what herdr reports for a tab nobody has renamed, its
/// own 1-based position.
private func makeModel(workspaceLabel: String = "seed", tabs: [(String, [String], String?)]) -> SessionModel {
    let tabJSON = tabs.enumerated().map { index, entry in
        #"{"tab_id":"\#(entry.0)","workspace_id":"w1","label":"\#(entry.2 ?? String(index + 1))","number":\#(index + 1),"pane_count":\#(entry.1.count),"agent_status":"unknown"}"#
    }
    let paneJSON = tabs.flatMap { entry in
        entry.1.map { pane in
            #"{"pane_id":"\#(pane)","workspace_id":"w1","tab_id":"\#(entry.0)","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"}"#
        }
    }
    let snapshotJSON = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"\#(tabs[0].0)","focused_pane_id":null,"workspaces":[{"workspace_id":"w1","label":"\#(workspaceLabel)","number":4,"active_tab_id":"\#(tabs[0].0)","agent_status":"unknown"}],"tabs":[\#(tabJSON.joined(separator: ","))],"panes":[\#(paneJSON.joined(separator: ","))],"layouts":[]}
    """#
    let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
    return SessionModel(snapshot: snapshot)
}

final class PaneCloseConsequenceTests: XCTestCase {
    /// The common case, and the one that must stay instant: nothing is lost
    /// but the pane, so there is nothing to ask about.
    func testAPaneWithSiblingsTakesNothingWithIt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1", "w1:p2"], nil)])

        let consequence = PaneCloseConsequence.of(pane: PaneID(rawValue: "w1:p1"), model: model)

        XCTAssertEqual(consequence, .paneOnly)
        XCTAssertNil(consequence.confirmation(closing: PaneID(rawValue: "w1:p1")))
    }

    func testTheLastPaneOfATabTakesTheTab() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], "Deploy logs"), ("w1:t2", ["w1:p2"], nil)])

        let consequence = PaneCloseConsequence.of(pane: PaneID(rawValue: "w1:p1"), model: model)

        XCTAssertEqual(consequence, .closesTab(description: "the tab \"Deploy logs\""))
    }

    /// herdr labels a tab nobody has renamed with its own 1-based position, so
    /// that string is a place and not a name: quoting it as one would put
    /// "2" in the prompt as if the user had typed it.
    func testAnUnrenamedTabIsNamedByItsPosition() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], nil), ("w1:t2", ["w1:p2"], nil)])

        let consequence = PaneCloseConsequence.of(pane: PaneID(rawValue: "w1:p2"), model: model)

        XCTAssertEqual(consequence, .closesTab(description: "tab 2"))
    }

    func testTheLastPaneOfTheLastTabTakesTheWorkspace() {
        let model = makeModel(workspaceLabel: "flock", tabs: [("w1:t1", ["w1:p1"], nil)])

        let consequence = PaneCloseConsequence.of(pane: PaneID(rawValue: "w1:p1"), model: model)

        XCTAssertEqual(consequence, .closesWorkspace(description: "the workspace \"flock\""))
    }

    /// A prompt that does not say what it is destroying is not a prompt. Both
    /// escalated rungs name the thing and the verb that takes it.
    func testTheTabPromptNamesTheTabAndTheVerb() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], "Deploy logs"), ("w1:t2", ["w1:p2"], nil)])
        let pane = PaneID(rawValue: "w1:p1")

        let confirmation = PaneCloseConsequence.of(pane: pane, model: model).confirmation(closing: pane)

        XCTAssertEqual(confirmation?.paneID, pane)
        XCTAssertEqual(confirmation?.title, "Close the tab \"Deploy logs\"?")
        XCTAssertEqual(confirmation?.confirmButtonTitle, "Close Tab")
        XCTAssertEqual(
            confirmation?.message,
            "This is its last pane, so closing the pane closes the tab. A close cannot be undone.")
    }

    func testTheWorkspacePromptNamesTheWorkspaceAndTheVerb() {
        let model = makeModel(workspaceLabel: "flock", tabs: [("w1:t1", ["w1:p1"], nil)])
        let pane = PaneID(rawValue: "w1:p1")

        let confirmation = PaneCloseConsequence.of(pane: pane, model: model).confirmation(closing: pane)

        XCTAssertEqual(confirmation?.title, "Close the workspace \"flock\"?")
        XCTAssertEqual(confirmation?.confirmButtonTitle, "Close Workspace")
        XCTAssertEqual(
            confirmation?.message,
            "This is its last pane, so closing the pane closes the tab and the workspace with it. "
                + "A close cannot be undone.")
    }

    /// A workspace herdr has left unlabelled still has to be named as some
    /// particular one, since the prompt's whole job is saying which.
    func testAnUnlabelledWorkspaceIsNamedByItsNumber() {
        let model = makeModel(workspaceLabel: "", tabs: [("w1:t1", ["w1:p1"], nil)])

        let consequence = PaneCloseConsequence.of(pane: PaneID(rawValue: "w1:p1"), model: model)

        XCTAssertEqual(consequence, .closesWorkspace(description: "workspace 4"))
    }

    /// A pane the model does not carry escalates to nothing: the close goes
    /// out and herdr rejects it, which is what a stale id already did.
    func testAnUnknownPaneRaisesNoPrompt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], nil)])

        XCTAssertEqual(PaneCloseConsequence.of(pane: PaneID(rawValue: "w9:p9"), model: model), .paneOnly)
    }
}
