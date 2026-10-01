import XCTest
@testable import FlockCore

final class TabChatPresenceTests: XCTestCase {
    /// `w1:t1` holds `w1:p1` (right half) and `w1:p2` (left half), so reading
    /// order and pane id order disagree; `w1:t2` holds `w1:p3`.
    private func model() throws -> SessionModel {
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"pane_count":2,"agent_status":"unknown"},{"tab_id":"w1:t2","workspace_id":"w1","label":"2","number":2,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"},{"pane_id":"w1:p3","workspace_id":"w1","tab_id":"w1:t2","focused":false,"agent_status":"unknown","revision":0,"cwd":"/tmp"}],"layouts":[]}
        """#
        var model = SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
        model.layouts[TabID(rawValue: "w1:t1")] = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: PaneID(rawValue: "w1:p1"),
            panes: [
                PaneRect(paneID: PaneID(rawValue: "w1:p1"), focused: true, rect: CellRect(x: 40, y: 0, width: 40, height: 24)),
                PaneRect(paneID: PaneID(rawValue: "w1:p2"), focused: false, rect: CellRect(x: 0, y: 0, width: 40, height: 24)),
            ],
            splits: []
        )
        return model
    }

    private func buddy(_ handle: String, name: String? = nil, pane: String) -> ChatBuddy {
        ChatBuddy(
            handle: handle, name: name, paneID: pane, status: "online", repo: nil, branch: nil, title: nil, unread: 0, mentions: 0
        )
    }

    private func label(_ tab: String, _ buddies: [ChatBuddy]) throws -> String? {
        let model = try model()
        let record = try XCTUnwrap(model.tabs[WorkspaceID(rawValue: "w1")]?.first { $0.tabID == TabID(rawValue: tab) })
        let byPane = Dictionary(uniqueKeysWithValues: buddies.map { (PaneID(rawValue: $0.paneID), $0) })
        return TabChatPresence.label(for: record, in: model, buddies: byPane)
    }

    func testATabWithNobodySignedInSaysNothing() throws {
        XCTAssertNil(try label("w1:t1", []))
    }

    func testOneSignedInPaneShowsItsName() throws {
        XCTAssertEqual(try label("w1:t1", [buddy("@ivy-claude", name: "Ivy", pane: "w1:p1")]), "Ivy")
    }

    func testAHandleWithoutANameIsShownWithoutItsAt() throws {
        XCTAssertEqual(try label("w1:t1", [buddy("@ivy-claude", pane: "w1:p1")]), "ivy-claude")
    }

    func testMoreThanOneShowsTheFirstInReadingOrderAndHowManyMore() throws {
        let buddies = [buddy("@right", pane: "w1:p1"), buddy("@left", pane: "w1:p2")]
        XCTAssertEqual(try label("w1:t1", buddies), "left · 1 more", "the left pane reads first")
    }

    func testSomeoneInAnotherTabIsNotCounted() throws {
        XCTAssertNil(try label("w1:t1", [buddy("@elsewhere", pane: "w1:p3")]))
        XCTAssertEqual(try label("w1:t2", [buddy("@elsewhere", pane: "w1:p3")]), "elsewhere", "a tab with no layout yet still counts its pane")
    }
}
