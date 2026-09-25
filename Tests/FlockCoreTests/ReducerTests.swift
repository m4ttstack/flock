import XCTest
@testable import FlockCore

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

    /// A workspace's dot is the loudest of its panes. Closing the tab that
    /// held the loudest one has to bring the dot down to what is left, or a
    /// closed "done" tab keeps the workspace blue over tabs that are working.
    func testClosingATabRecountsItsWorkspacesStatus() throws {
        var model = try seededModel()
        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p1"), .working), to: &model)
        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p2"), .working), to: &model)
        apply(.paneAgentStatusChanged(PaneID(rawValue: "w1:p3"), .done), to: &model)
        XCTAssertEqual(model.workspaces.first { $0.workspaceID == WorkspaceID(rawValue: "w1") }?.agentStatus, .done)

        apply(.tabClosed(TabID(rawValue: "w1:t2")), to: &model)

        XCTAssertEqual(model.workspaces.first { $0.workspaceID == WorkspaceID(rawValue: "w1") }?.agentStatus, .working)
    }

    /// A reorder hands back whole workspace records, status and all. The dot
    /// still follows the panes, so a stale "done" in that payload cannot
    /// paint a workspace blue over working tabs.
    func testAWorkspaceReorderCannotSetAStatusItsPanesDisagreeWith() throws {
        var model = try seededModel()
        for pane in ["w1:p1", "w1:p2", "w1:p3"] {
            apply(.paneAgentStatusChanged(PaneID(rawValue: pane), .working), to: &model)
        }
        let stale = model.workspaces.map { record -> WorkspaceRecord in
            var record = record
            record.agentStatus = .done
            return record
        }

        apply(.workspaceReordered(stale), to: &model)

        XCTAssertEqual(model.workspaces.first { $0.workspaceID == WorkspaceID(rawValue: "w1") }?.agentStatus, .working)
    }

    /// `pane_updated` carries the pane's status too; the tab and workspace
    /// dots follow it the same as a status-changed frame.
    func testAPaneUpdateCarriesItsStatusUpToTheTabAndWorkspace() throws {
        var model = try seededModel()
        for pane in ["w1:p1", "w1:p2", "w1:p3"] {
            apply(.paneAgentStatusChanged(PaneID(rawValue: pane), .idle), to: &model)
        }
        var updated = try XCTUnwrap(model.panes[PaneID(rawValue: "w1:p3")])
        updated.agentStatus = .blocked

        apply(.paneUpdated(updated), to: &model)

        XCTAssertEqual(model.tabs[WorkspaceID(rawValue: "w1")]?.first { $0.tabID == updated.tabID }?.agentStatus, .blocked)
        XCTAssertEqual(model.workspaces.first { $0.workspaceID == WorkspaceID(rawValue: "w1") }?.agentStatus, .blocked)
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

    /// A pane record can be a layout ahead of the layouts: `.paneMoved` re-keys
    /// the record's tab and deliberately leaves every layout's pane list alone.
    /// Writing the focus there anyway would leave a layout naming a pane it
    /// does not hold, which `LayoutSnapshot.focusedPane` then hands out as a
    /// mutation target.
    func testPaneFocusedLeavesALayoutThatDoesNotHoldThePaneAlone() throws {
        var model = try seededModel()
        let destination = TabID(rawValue: "w1:t2")
        let pane = PaneID(rawValue: "w1:p2")
        let focusBefore = model.layouts[destination]?.focusedPaneID
        let record = try XCTUnwrap(model.panes[pane])
        model.panes[pane] = PaneRecord(
            paneID: record.paneID, workspaceID: record.workspaceID, tabID: destination, focused: record.focused,
            agentStatus: record.agentStatus, revision: record.revision,
            terminalTitleStripped: record.terminalTitleStripped, label: record.label, cwd: record.cwd, scroll: record.scroll
        )
        XCTAssertFalse(
            model.layouts[destination]?.panes.contains { $0.paneID == pane } ?? true,
            "this case reads a layout that does not yet list the moved pane"
        )

        apply(.paneFocused(pane), to: &model)

        XCTAssertEqual(model.focusedPaneID, pane)
        XCTAssertEqual(model.layouts[destination]?.focusedPaneID, focusBefore)
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

    /// `LayoutSnapshot.focusedPane` prefers `focusedPaneID` over its
    /// first-pane fallback, and `MutationEngine` sends what it returns to
    /// herdr as a real target (the pane an unzoom lands on), so a focus left
    /// naming the pane that just closed is a plan herdr rejects rather than an
    /// inert stale id.
    func testPaneClosedClearsAFocusLeftPointingAtTheDeadPane() throws {
        var model = try seededModel()
        let tabID = TabID(rawValue: "w1:t1")
        let closed = PaneID(rawValue: "w1:p1")
        XCTAssertEqual(model.focusedPaneID, closed)
        XCTAssertEqual(model.layouts[tabID]?.focusedPaneID, closed)

        apply(.paneClosed(closed), to: &model)

        XCTAssertNil(model.layouts[tabID]?.focusedPaneID)
        XCTAssertEqual(model.layouts[tabID]?.focusedPane, PaneID(rawValue: "w1:p2"), "the fallback is what a consumer must reach")
        XCTAssertNil(model.focusedPaneID)
        XCTAssertEqual(model.layouts[TabID(rawValue: "w1:t2")]?.focusedPaneID, PaneID(rawValue: "w1:p3"), "another tab's focus moved")
    }

    func testPaneClosedLeavesAFocusOnAPaneThatIsStillThereAlone() throws {
        var model = try seededModel()
        let tabID = TabID(rawValue: "w1:t1")

        apply(.paneClosed(PaneID(rawValue: "w1:p2")), to: &model)

        XCTAssertEqual(model.layouts[tabID]?.focusedPaneID, PaneID(rawValue: "w1:p1"))
        XCTAssertEqual(model.focusedPaneID, PaneID(rawValue: "w1:p1"))
    }

    /// herdr's `Workspace::close_pane` removes the tab whose last pane just
    /// left, and says so with no event of its own: a `pane.close` that empties
    /// a tab emits `PaneClosed` and nothing else. Without this the tab keeps
    /// its place in the strip, over a layout with no panes in it, until the
    /// five-minute resnapshot. `w1:t2` owns exactly one pane, `w1:p3`.
    func testPaneClosedClosesTheTabItEmptied() throws {
        var model = try seededModel()

        apply(.paneClosed(PaneID(rawValue: "w1:p3")), to: &model)

        XCTAssertFalse(
            model.tabs.values.contains { tabs in tabs.contains { $0.tabID == TabID(rawValue: "w1:t2") } },
            "the tab its last pane left must go with it")
        XCTAssertNil(model.layouts[TabID(rawValue: "w1:t2")])
        XCTAssertTrue(model.workspaces.contains { $0.workspaceID == WorkspaceID(rawValue: "w1") }, "its workspace has another tab")
        XCTAssertNotNil(model.panes[PaneID(rawValue: "w1:p1")], "the surviving tab's panes are untouched")
    }

    /// The escalation herdr stops short of here: a workspace whose last tab
    /// would go gets a `WorkspaceClosed` of its own, so leaving the tab for
    /// that event is what keeps flock from inventing a workspace with no tabs,
    /// a state herdr never has.
    func testPaneClosedLeavesAWorkspacesLastTabToTheWorkspaceEvent() throws {
        var model = try seededModel()
        apply(.tabClosed(TabID(rawValue: "w1:t1")), to: &model)

        apply(.paneClosed(PaneID(rawValue: "w1:p3")), to: &model)

        XCTAssertTrue(
            model.tabs.values.contains { tabs in tabs.contains { $0.tabID == TabID(rawValue: "w1:t2") } },
            "a workspace's last tab is the workspace close's to take")
    }

    /// A pane leaving a tab that still holds others closes nothing but itself.
    func testPaneClosedLeavesATabThatStillHoldsPanes() throws {
        var model = try seededModel()

        apply(.paneClosed(PaneID(rawValue: "w1:p2")), to: &model)

        XCTAssertTrue(
            model.tabs.values.contains { tabs in tabs.contains { $0.tabID == TabID(rawValue: "w1:t1") } })
        XCTAssertNotNil(model.layouts[TabID(rawValue: "w1:t1")])
    }

    /// A pane whose program exits is gone from herdr, which says so with
    /// `PaneExited` alone: `handle_pane_died` removes the pane, the tab it
    /// emptied and the workspace that tab was the last of, and emits no
    /// `PaneClosed`, `TabClosed` or `WorkspaceClosed` for any of them.
    func testPaneExitedRemovesThePaneFromItsTab() throws {
        var model = try seededModel()
        let exited = PaneID(rawValue: "w1:p2")

        apply(.paneExited(exited), to: &model)

        XCTAssertNil(model.panes[exited])
        XCTAssertFalse(model.layouts[TabID(rawValue: "w1:t1")]?.panes.contains { $0.paneID == exited } ?? true)
        XCTAssertNotNil(model.layouts[TabID(rawValue: "w1:t1")], "the tab still holds w1:p1")
    }

    func testPaneExitedClosesTheTabItEmptied() throws {
        var model = try seededModel()

        apply(.paneExited(PaneID(rawValue: "w1:p3")), to: &model)

        XCTAssertFalse(model.tabs.values.contains { tabs in tabs.contains { $0.tabID == TabID(rawValue: "w1:t2") } })
        XCTAssertNil(model.layouts[TabID(rawValue: "w1:t2")])
        XCTAssertTrue(model.workspaces.contains { $0.workspaceID == WorkspaceID(rawValue: "w1") })
    }

    func testPaneExitedClosesTheWorkspaceWhoseLastTabItEmptied() throws {
        var model = try seededModel()
        apply(.tabClosed(TabID(rawValue: "w1:t1")), to: &model)

        apply(.paneExited(PaneID(rawValue: "w1:p3")), to: &model)

        XCTAssertFalse(model.workspaces.contains { $0.workspaceID == WorkspaceID(rawValue: "w1") })
        XCTAssertNil(model.tabs[WorkspaceID(rawValue: "w1")])
        XCTAssertTrue(model.panes.isEmpty)
    }

    /// The other two paths that delete panes. herdr emits no `PaneClosed` for
    /// the panes a closed tab or workspace took with it, so the session focus
    /// is left naming one of them here too.
    func testClosingATabOrAWorkspaceClearsASessionFocusItTookWithIt() throws {
        var byTab = try seededModel()
        apply(.tabClosed(TabID(rawValue: "w1:t1")), to: &byTab)
        XCTAssertNil(byTab.focusedPaneID)

        var byWorkspace = try seededModel()
        apply(.workspaceClosed(WorkspaceID(rawValue: "w1")), to: &byWorkspace)
        XCTAssertNil(byWorkspace.focusedPaneID)
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

    /// Selecting a workspace reads its `activeTabID` to decide where to land.
    /// Left to the snapshot alone that is stale the moment anyone switches
    /// tabs, and the window shows the snapshot's tab before jumping to the
    /// real one.
    func testTabFocusedMovesTheOwningWorkspacesActiveTab() throws {
        var model = try seededModel()
        let workspace = WorkspaceID(rawValue: "w1")
        let second = TabID(rawValue: "w1:t2")
        XCTAssertEqual(
            model.workspaces.first { $0.workspaceID == workspace }?.activeTabID,
            TabID(rawValue: "w1:t1")
        )

        apply(.tabFocused(second), to: &model)

        XCTAssertEqual(model.focusedTabID, second)
        XCTAssertEqual(model.workspaces.first { $0.workspaceID == workspace }?.activeTabID, second)
    }

    /// A focus in one workspace says nothing about where another should land.
    func testTabFocusedLeavesOtherWorkspacesAlone() throws {
        var model = try seededModel()
        let other = WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: "w2"),
            label: "second",
            number: 2,
            activeTabID: TabID(rawValue: "w2:t1"),
            agentStatus: .unknown
        )
        model.workspaces.append(other)
        model.tabs[other.workspaceID] = []

        apply(.tabFocused(TabID(rawValue: "w1:t2")), to: &model)

        XCTAssertEqual(
            model.workspaces.first { $0.workspaceID == other.workspaceID }?.activeTabID,
            TabID(rawValue: "w2:t1")
        )
    }
}
