import XCTest
@testable import FlockCore

final class TabTitleTests: XCTestCase {
    /// `w1:t1` labelled `tabLabel`, holding one pane per entry of `panes`
    /// (its label and terminal title, either of which may be absent).
    private func model(tabLabel: String, panes: [(label: String?, title: String?)]) throws -> SessionModel {
        let paneJSON = panes.enumerated().map { index, pane in
            let label = pane.label.map { #","label":"\#($0)""# } ?? ""
            let title = pane.title.map { #","terminal_title_stripped":"\#($0)""# } ?? ""
            return #"{"pane_id":"w1:p\#(index + 1)","workspace_id":"w1","tab_id":"w1:t1","focused":\#(index == 0),"agent_status":"unknown","revision":0,"cwd":"/tmp"\#(label)\#(title)}"#
        }.joined(separator: ",")
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"\#(tabLabel)","number":4,"pane_count":\#(panes.count),"agent_status":"unknown"}],"panes":[\#(paneJSON)],"layouts":[]}
        """#
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    private func title(_ model: SessionModel) throws -> TabTitle {
        TabTitle.resolve(try XCTUnwrap(model.tabs[WorkspaceID(rawValue: "w1")]?.first), in: model)
    }

    func testAnUnnamedTabWithOnePaneShowsThatPanesTitle() throws {
        let model = try model(tabLabel: "1", panes: [(nil, "✳ Fixing tab sizes")])
        XCTAssertEqual(try title(model), TabTitle(text: "✳ Fixing tab sizes", isFromPane: true))
    }

    func testThePanesOwnNameWinsOverWhatItsProgramSets() throws {
        let model = try model(tabLabel: "1", panes: [("release", "✳ Fixing tab sizes")])
        XCTAssertEqual(try title(model), TabTitle(text: "release", isFromPane: true))
    }

    func testARenamedTabKeepsItsName() throws {
        let model = try model(tabLabel: "notes", panes: [(nil, "✳ Fixing tab sizes")])
        XCTAssertEqual(try title(model), TabTitle(text: "notes", isFromPane: false))
    }

    func testAnUnnamedTabWithTwoPanesKeepsItsNumber() throws {
        let model = try model(tabLabel: "2", panes: [(nil, "zsh"), (nil, "vim")])
        XCTAssertEqual(try title(model), TabTitle(text: "2", isFromPane: false))
    }

    /// herdr numbers an unnamed tab by its place in the strip, which is
    /// neither its public `number` nor stable across a move.
    func testAnyNumberIsAnUnnamedTabWhateverItsPlace() {
        for label in ["1", "3", "12", ""] {
            XCTAssertTrue(TabTitle.isAutoNamed(label), label)
        }
        for label in ["notes", "v2", "1a", "2 agents"] {
            XCTAssertFalse(TabTitle.isAutoNamed(label), label)
        }
    }

    @MainActor
    func testTheSwitcherReadsTheSameRuleForAnUnnamedTab() throws {
        var model = try model(tabLabel: "1", panes: [(nil, "zsh"), (nil, "vim")])
        model.layouts[TabID(rawValue: "w1:t1")] = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: PaneID(rawValue: "w1:p1"),
            panes: [PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: CellRect(x: 0, y: 0, width: 80, height: 24))],
            splits: []
        )
        let tab = try XCTUnwrap(model.tabs[WorkspaceID(rawValue: "w1")]?.first)
        XCTAssertEqual(TabSwitcher.title(for: tab, in: model), "[zsh]", "label 1 on tab number 4 is still herdr's own")
    }

    func testRenamingAPaneTitledTabStartsFromWhatItShows() throws {
        let model = try model(tabLabel: "1", panes: [(nil, "✳ Fixing tab sizes")])
        let target = RenameTarget.tab(TabID(rawValue: "w1:t1"))
        XCTAssertEqual(RenameEditor.initialText(for: target, model: model), "✳ Fixing tab sizes")
        XCTAssertNil(RenameEditor.commit("✳ Fixing tab sizes", for: target, model: model), "an untouched field renames nothing")
        XCTAssertNotNil(RenameEditor.commit("agents", for: target, model: model))
    }
}
