import XCTest
@testable import PaddockCore

final class ReducerTests: XCTestCase {
    func seededModel() throws -> SessionModel {
        let snapshot = try HerdrDecoder.snapshot(fromResponseLine: try fixture("snapshot.json"))
        return SessionModel(snapshot: snapshot)
    }

    func testPaneMovedReKeysPane() throws {
        var model = try seededModel()
        let newWorkspace = WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: "w2"),
            label: "second",
            number: 2,
            activeTabID: TabID(rawValue: "w2:t1"),
            agentStatus: .unknown
        )
        let movedPane = PaneRecord(
            paneID: PaneID(rawValue: "w2:p9"),
            workspaceID: WorkspaceID(rawValue: "w2"),
            tabID: TabID(rawValue: "w2:t1"),
            focused: true,
            agentStatus: .unknown,
            revision: 0,
            terminalTitleStripped: nil,
            label: nil,
            cwd: "/private/tmp",
            scroll: nil
        )
        let payload = PaneMovedPayload(
            previousPaneID: PaneID(rawValue: "w1:p2"),
            previousWorkspaceID: WorkspaceID(rawValue: "w1"),
            previousTabID: TabID(rawValue: "w1:t1"),
            pane: movedPane,
            createdTab: nil,
            createdWorkspace: newWorkspace,
            closedTabID: nil,
            closedWorkspaceID: nil
        )

        apply(.paneMoved(payload), to: &model)

        XCTAssertNil(model.panes[PaneID(rawValue: "w1:p2")])
        XCTAssertEqual(model.panes[PaneID(rawValue: "w2:p9")], movedPane)
        XCTAssertTrue(model.workspaces.contains { $0.workspaceID == newWorkspace.workspaceID })
    }

    func testWorkspaceReorderReplacesOrder() throws {
        var model = try seededModel()
        let workspaceB = WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: "wB"),
            label: "B",
            number: 2,
            activeTabID: TabID(rawValue: "wB:t1"),
            agentStatus: .unknown
        )
        let workspaceA = WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: "wA"),
            label: "A",
            number: 1,
            activeTabID: TabID(rawValue: "wA:t1"),
            agentStatus: .unknown
        )

        apply(.workspaceReordered([workspaceB, workspaceA]), to: &model)

        XCTAssertEqual(model.workspaces.map(\.workspaceID), [workspaceB.workspaceID, workspaceA.workspaceID])
    }

    func testLayoutUpdatedReplacesOnlyThatTab() throws {
        var model = try seededModel()
        let tabAID = TabID(rawValue: "w1:t1")
        let tabBID = TabID(rawValue: "w1:t2")
        let originalTabBLayout = model.layouts[tabBID]
        XCTAssertNotNil(model.layouts[tabAID])
        XCTAssertNotNil(originalTabBLayout)

        let replacementLayout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: tabAID,
            zoomed: true,
            area: CellRect(x: 0, y: 0, width: 10, height: 10),
            focusedPaneID: nil,
            panes: [],
            splits: []
        )

        apply(.layoutUpdated(replacementLayout), to: &model)

        XCTAssertEqual(model.layouts[tabAID], replacementLayout)
        XCTAssertEqual(model.layouts[tabBID], originalTabBLayout)
    }

    /// herdr's own `tab.close` emits only `TabClosed` -- no `PaneClosed`
    /// per pane -- so `removeTab` has to prune `model.panes` itself, the
    /// same way `removeWorkspace` already does for a closed workspace.
    /// `w1:t2` (the fixture's second tab) owns exactly one pane, `w1:p3`.
    func testTabClosedPrunesItsOwnPanesToo() throws {
        var model = try seededModel()
        XCTAssertNotNil(model.panes[PaneID(rawValue: "w1:p3")])

        apply(.tabClosed(TabID(rawValue: "w1:t2")), to: &model)

        XCTAssertNil(model.panes[PaneID(rawValue: "w1:p3")], "a closed tab's own panes must not linger in the model")
        XCTAssertNil(model.layouts[TabID(rawValue: "w1:t2")])
        XCTAssertFalse(
            model.tabs.values.contains { tabs in tabs.contains { $0.tabID == TabID(rawValue: "w1:t2") } },
            "the closed tab itself must be gone too")
        // Panes belonging to the OTHER (still-open) tab must be untouched.
        XCTAssertNotNil(model.panes[PaneID(rawValue: "w1:p1")])
        XCTAssertNotNil(model.panes[PaneID(rawValue: "w1:p2")])
    }

    func testPaneScrollChangedReplacesThatPanesScrollOnly() throws {
        var model = try seededModel()
        let scrolled = ScrollInfo(offsetFromBottom: 12, maxOffsetFromBottom: 200, viewportRows: 23)
        let untouched = model.panes[PaneID(rawValue: "w1:p2")]?.scroll

        apply(.paneScrollChanged(PaneID(rawValue: "w1:p1"), scrolled), to: &model)

        XCTAssertEqual(model.panes[PaneID(rawValue: "w1:p1")]?.scroll, scrolled)
        XCTAssertEqual(model.panes[PaneID(rawValue: "w1:p2")]?.scroll, untouched)
    }

    func testPaneScrollChangedForAnUnknownPaneIsANoOp() throws {
        let before = try seededModel()
        var after = before

        apply(.paneScrollChanged(PaneID(rawValue: "w9:p9"), ScrollInfo(offsetFromBottom: 1, maxOffsetFromBottom: 1, viewportRows: 1)), to: &after)

        XCTAssertEqual(after, before)
    }

    /// herdr derives a layout's `focused_pane_id` from the same
    /// `tab.layout.focused()` this event reports, and sends no `layout.updated`
    /// when focus alone moves. A layout left naming the previous pane is what
    /// makes a zoomed canvas hold open a pane herdr has stopped showing, until
    /// the next full snapshot minutes later.
    func testPaneFocusedMovesTheOwningTabsLayoutFocusToo() throws {
        var model = try seededModel()
        let tabID = TabID(rawValue: "w1:t1")
        let otherTab = TabID(rawValue: "w1:t2")
        let otherTabFocus = model.layouts[otherTab]?.focusedPaneID
        XCTAssertEqual(model.layouts[tabID]?.focusedPaneID, PaneID(rawValue: "w1:p1"))

        apply(.paneFocused(PaneID(rawValue: "w1:p2")), to: &model)

        XCTAssertEqual(model.focusedPaneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(model.layouts[tabID]?.focusedPaneID, PaneID(rawValue: "w1:p2"))
        XCTAssertEqual(model.layouts[otherTab]?.focusedPaneID, otherTabFocus, "another tab's own focus moved")
    }

    /// A pane no snapshot has reported yet names no tab, so there is no layout
    /// to move: the session's focus still follows, and no layout is guessed at.
    func testPaneFocusedOnAnUnknownPaneLeavesEveryLayoutAlone() throws {
        var model = try seededModel()
        let before = model.layouts

        apply(.paneFocused(PaneID(rawValue: "w9:p9")), to: &model)

        XCTAssertEqual(model.focusedPaneID, PaneID(rawValue: "w9:p9"))
        XCTAssertEqual(model.layouts, before)
    }

    func testUnknownEventIsNoOp() throws {
        let before = try seededModel()
        var after = before

        apply(.unknown(type: "pane.hologram"), to: &after)

        XCTAssertEqual(after, before)
    }

    func testEventFixtureReplayEndsConsistent() throws {
        var model = try seededModel()

        for line in try fixtureLines("events.ndjson") {
            guard let event = try? HerdrDecoder.event(fromLine: line) else { continue }
            apply(event, to: &model)
        }

        for (tabID, layout) in model.layouts {
            for paneRect in layout.panes {
                XCTAssertNotNil(model.panes[paneRect.paneID], "pane \(paneRect.paneID) referenced by layout \(tabID) is missing from panes")
            }
            let tabExists = model.tabs.values.contains { tabs in tabs.contains { $0.tabID == tabID } }
            XCTAssertTrue(tabExists, "layout key \(tabID) has no owning tab in any workspace")
        }
    }
}
