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

final class CloseConsequenceTests: XCTestCase {
    /// The common case, and the one that must stay instant: nothing is lost
    /// but the pane, so there is nothing to ask about.
    func testAPaneWithSiblingsTakesNothingWithIt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1", "w1:p2"], nil)])

        let consequence = CloseConsequence.of(.pane(PaneID(rawValue: "w1:p1")), model: model)

        XCTAssertEqual(consequence, .subjectOnly)
        XCTAssertNil(consequence.confirmation(closing: .pane(PaneID(rawValue: "w1:p1"))))
    }

    func testTheLastPaneOfATabTakesTheTab() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], "Deploy logs"), ("w1:t2", ["w1:p2"], nil)])

        let consequence = CloseConsequence.of(.pane(PaneID(rawValue: "w1:p1")), model: model)

        XCTAssertEqual(consequence, .closesTab(description: "Deploy logs"))
    }

    /// herdr labels a tab nobody has renamed with its own 1-based position;
    /// the strip shows a lone pane's title there instead, and so does the
    /// prompt.
    func testAnUnrenamedTabOfOnePaneIsNamedAsTheStripNamesIt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], nil), ("w1:t2", ["w1:p2"], nil)])

        let consequence = CloseConsequence.of(.pane(PaneID(rawValue: "w1:p2")), model: model)

        XCTAssertEqual(consequence, .closesTab(description: "shell"))
    }

    /// A position is a place, not a name: "Close Tab 2", never "Close Tab: 2".
    func testAPositionIsNotQuotedAsAName() {
        XCTAssertEqual(CloseConsequence.heading(noun: "tab", name: "2"), "Close Tab 2")
        XCTAssertEqual(CloseConsequence.heading(noun: "tab", name: "Deploy logs"), "Close Tab: Deploy logs")
    }

    /// The card shows the name apart from the action; a number stays in it.
    func testTheActionAndTheNameComeApart() {
        XCTAssertEqual(CloseConsequence.headingParts(noun: "pane", name: "Boxed setting").action, "Close Pane")
        XCTAssertEqual(CloseConsequence.headingParts(noun: "pane", name: "Boxed setting").name, "Boxed setting")
        XCTAssertEqual(CloseConsequence.headingParts(noun: "tab", name: "2").action, "Close Tab 2")
        XCTAssertNil(CloseConsequence.headingParts(noun: "tab", name: "2").name)
        XCTAssertNil(CloseConsequence.headingParts(noun: "tab", name: nil).name)
    }

    func testALongNameIsCutShort() {
        let name = String(repeating: "a", count: CloseConsequence.nameLimit + 5)
        let heading = CloseConsequence.heading(noun: "tab", name: name)

        XCTAssertEqual(heading, "Close Tab: " + String(repeating: "a", count: CloseConsequence.nameLimit - 1) + "…")
    }

    func testTheLastPaneOfTheLastTabTakesTheWorkspace() {
        let model = makeModel(workspaceLabel: "flock", tabs: [("w1:t1", ["w1:p1"], nil)])

        let consequence = CloseConsequence.of(.pane(PaneID(rawValue: "w1:p1")), model: model)

        XCTAssertEqual(consequence, .closesWorkspace(description: "flock"))
    }

    /// A prompt that does not say what it is destroying is not a prompt. Both
    /// escalated rungs name the thing and the verb that takes it.
    func testTheTabPromptNamesTheTabAndTheVerb() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], "Deploy logs"), ("w1:t2", ["w1:p2"], nil)])
        let pane = CloseSubject.pane(PaneID(rawValue: "w1:p1"))

        let confirmation = CloseConsequence.of(pane, model: model).confirmation(closing: pane)

        XCTAssertEqual(confirmation?.subject, pane)
        XCTAssertEqual(confirmation?.title, "Close Tab: Deploy logs")
        XCTAssertEqual(confirmation?.confirmButtonTitle, "Close Tab")
        XCTAssertEqual(confirmation?.message, "This is the last pane in the tab, so the tab closes with it.")
    }

    func testTheWorkspacePromptNamesTheWorkspaceAndTheVerb() {
        let model = makeModel(workspaceLabel: "flock", tabs: [("w1:t1", ["w1:p1"], nil)])
        let pane = CloseSubject.pane(PaneID(rawValue: "w1:p1"))

        let confirmation = CloseConsequence.of(pane, model: model).confirmation(closing: pane)

        XCTAssertEqual(confirmation?.title, "Close Workspace: flock")
        XCTAssertEqual(confirmation?.confirmButtonTitle, "Close Workspace")
        XCTAssertEqual(confirmation?.message, "This is the last pane in the workspace, so the workspace closes with it.")
    }

    /// A workspace herdr has left unlabelled still has to be named as some
    /// particular one, since the prompt's whole job is saying which.
    func testAnUnlabelledWorkspaceIsNamedByItsNumber() {
        let model = makeModel(workspaceLabel: "", tabs: [("w1:t1", ["w1:p1"], nil)])

        let consequence = CloseConsequence.of(.pane(PaneID(rawValue: "w1:p1")), model: model)

        XCTAssertEqual(consequence, .closesWorkspace(description: "4"))
    }

    /// A pane the model does not carry escalates to nothing: the close goes
    /// out and herdr rejects it, which is what a stale id already did.
    func testAnUnknownPaneRaisesNoPrompt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], nil)])

        XCTAssertEqual(CloseConsequence.of(.pane(PaneID(rawValue: "w9:p9")), model: model), .subjectOnly)
    }

    // MARK: - closing a tab

    /// The common case for the other entry point, and it stays instant for the
    /// same reason: the tab is what the user asked to lose.
    func testATabAmongTabsTakesNothingWithIt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], nil), ("w1:t2", ["w1:p2"], nil)])

        let consequence = CloseConsequence.of(.tab(TabID(rawValue: "w1:t1")), model: model)

        XCTAssertEqual(consequence, .subjectOnly)
        XCTAssertNil(consequence.confirmation(closing: .tab(TabID(rawValue: "w1:t1"))))
    }

    /// `handle_tab_close` closes the workspace outright when the tab it is
    /// handed is the workspace's last, however many panes that tab holds.
    func testTheLastTabOfAWorkspaceTakesTheWorkspace() {
        let model = makeModel(workspaceLabel: "flock", tabs: [("w1:t1", ["w1:p1", "w1:p2"], nil)])

        let consequence = CloseConsequence.of(.tab(TabID(rawValue: "w1:t1")), model: model)

        XCTAssertEqual(consequence, .closesWorkspace(description: "flock"))
    }

    /// The prompt says which workspace, and says it in the closing tab's own
    /// terms rather than the pane prompt's.
    func testTheTabPromptNamesTheWorkspaceAndTheVerb() {
        let model = makeModel(workspaceLabel: "flock", tabs: [("w1:t1", ["w1:p1"], nil)])
        let tab = CloseSubject.tab(TabID(rawValue: "w1:t1"))

        let confirmation = CloseConsequence.of(tab, model: model).confirmation(closing: tab)

        XCTAssertEqual(confirmation?.subject, tab)
        XCTAssertEqual(confirmation?.title, "Close Workspace: flock")
        XCTAssertEqual(confirmation?.confirmButtonTitle, "Close Workspace")
        XCTAssertEqual(confirmation?.message, "This is the last tab in the workspace, so the workspace closes with it.")
    }

    func testAnUnknownTabRaisesNoPrompt() {
        let model = makeModel(tabs: [("w1:t1", ["w1:p1"], nil)])

        XCTAssertEqual(CloseConsequence.of(.tab(TabID(rawValue: "w9:t9")), model: model), .subjectOnly)
    }
}
