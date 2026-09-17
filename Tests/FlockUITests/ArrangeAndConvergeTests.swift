import XCTest

/// The rest of the inventory: the reorders a drag can make, the edits the
/// chrome and the pane menu can make, undo, and what the window does with
/// changes it did not make at all.
///
/// **Independence.** One herdr session serves a whole `xcodebuild test`
/// invocation, so `setUpWithError` reseeds it before every case and every case
/// launches its own app, terminated in a teardown block. Cases may be run in
/// any order or one at a time.
///
/// **Nothing may happen while a drag is in flight.** XCTest owns the machine
/// for the length of a gesture it started: it refuses to synthesize a key
/// until the gesture ends, it does not reliably turn the main run loop the
/// gesture blocks, and it hangs outright if the app under test stops being
/// frontmost. Every gesture here is one uninterrupted press-drag-release.
/// Keys and clicks BETWEEN gestures are ordinary and are how the editing
/// cases are driven.
///
/// **What a terminal draws is not in the accessibility tree.** A pane's
/// content reaches this suite only through herdr (`pane.read`), so the
/// typing case's window half is the click that moved focus and the cells the
/// canvas still draws, not the characters themselves.
final class ArrangeAndConvergeTests: XCTestCase {
    private var session: ScratchSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
    }

    // MARK: - Reorders

    /// A tab dragged past the first tab's centre takes the first slot. The
    /// strip's insert index is an item-CENTRE crossing rule, so the aim is
    /// inside the first tab rather than beyond it.
    @MainActor
    func testATabDraggedPastTheFirstTabsCentreLeadsTheStrip() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        let trace = dragElement(
            app, fromID: stripTab(ids.tabB), grabbing: .middle, toID: stripTab(ids.tabA), aiming: .edge(.left)
        )

        let after = try session.snapshot(waitingFor: "\(ids.tabB) to lead \(ids.ws). \(trace)") {
            $0.tabIDs(inWorkspace: ids.ws) == [ids.tabB, ids.tabA]
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2],
            "a strip reorder moves no pane; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB), [ids.p3],
            "a strip reorder moves no pane; \(after.outline())"
        )

        assertDrawnOrder(
            app, prefix: "flock.strip.tab.", along: .x, expected: [stripTab(ids.tabB), stripTab(ids.tabA)],
            "the strip did not redraw with \(ids.tabB) first"
        )
    }

    /// A workspace dragged below the last row's centre takes the last slot.
    @MainActor
    func testAWorkspaceDraggedBelowTheLastRowTakesTheLastSlot() throws {
        let ids = session.seedIDs()
        let other = try makeWorkspace(label: "other")
        let app = try launchOnSeed()
        waitForRailRows(app, [ids.ws, other.workspace])

        let trace = dragElement(
            app, fromID: railRow(ids.ws), grabbing: .middle, toID: railRow(other.workspace), aiming: .edge(.bottom)
        )

        let after = try session.snapshot(waitingFor: "\(ids.ws) to follow \(other.workspace). \(trace)") {
            $0.orderedWorkspaceIDs() == [other.workspace, ids.ws]
        }
        XCTAssertEqual(
            after.orderedWorkspaceLabels(), ["other", "seed"],
            "the rail order herdr holds is not the one the drag asked for; \(after.outline())"
        )
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "a rail reorder moves no tab; \(after.outline())"
        )

        assertDrawnOrder(
            app, prefix: "flock.rail.workspace.", along: .y,
            expected: [railRow(other.workspace), railRow(ids.ws)],
            "the rail did not redraw with \(other.workspace) first"
        )
    }

    /// Cmd+click makes a selection of two, and a drag from either of them
    /// carries both: herdr reorders the pair in ONE `workspace.move_block`,
    /// so the two never pass through an order where only one of them moved.
    /// A selection of two is what a single Cmd+click produces: it takes the
    /// current row along with the row clicked.
    @MainActor
    func testTwoSelectedWorkspacesMoveAsOneBlock() throws {
        let ids = session.seedIDs()
        let other = try makeWorkspace(label: "other")
        let third = try makeWorkspace(label: "third")
        let app = try launchOnSeed()
        waitForRailRows(app, [ids.ws, other.workspace, third.workspace])

        clickElement(app, railRow(other.workspace), holding: .command)
        // The one thing that separates a Cmd+click from a plain one before
        // the drag: a plain click jumps, and the selection it would have made
        // is a selection of nothing. herdr's focus is where that shows.
        try assertStaysTrue("the Cmd+click left herdr's focus alone rather than jumping to \(other.workspace)", for: 1) {
            try self.session.snapshot().focusedWorkspaceID == ids.ws
        }

        let trace = dragElement(
            app, fromID: railRow(other.workspace), grabbing: .middle,
            toID: railRow(third.workspace), aiming: .edge(.bottom)
        )

        let after = try snapshot(app, waitingFor: "the seed and \(other.workspace) to follow \(third.workspace). \(trace)") {
            $0.orderedWorkspaceIDs() == [third.workspace, ids.ws, other.workspace]
        }
        XCTAssertEqual(
            after.orderedWorkspaceLabels(), ["third", "seed", "other"],
            "the Cmd+click selection did not carry both rows; \(after.outline())"
        )

        assertDrawnOrder(
            app, prefix: "flock.rail.workspace.", along: .y,
            expected: [railRow(third.workspace), railRow(ids.ws), railRow(other.workspace)],
            "the rail did not redraw the moved block"
        )
    }

    /// A whole tab dragged onto another workspace's rail row is replayed
    /// there: herdr has no cross-workspace `tab.move`, so the plan moves every
    /// pane into a new tab one at a time and rebuilds the split shape, which
    /// re-keys them.
    @MainActor
    func testAWholeTabDraggedOntoAnotherWorkspaceKeepsItsSplitShape() throws {
        let ids = session.seedIDs()
        let other = try makeWorkspace(label: "other")
        let app = try launchOnSeed()
        waitForRailRows(app, [ids.ws, other.workspace])

        let trace = dragElement(
            app, fromID: stripTab(ids.tabA), grabbing: .middle, toID: railRow(other.workspace), aiming: .middle
        )

        // Both panes, in one wait: a migration that moves the anchor and
        // strands the rest leaves the destination holding a tab of one, and
        // waiting only for the tab would call that a pass.
        let after = try snapshot(app, waitingFor: "\(other.workspace) to gain a tab holding both panes. \(trace)") { truth in
            guard truth.tabCount(inWorkspace: other.workspace) == 2,
                  let landed = truth.tabIDs(inWorkspace: other.workspace).first(where: { $0 != other.tab })
            else { return false }
            return truth.paneIDs(inTab: landed).count == 2
        }
        let landed = try XCTUnwrap(
            after.tabIDs(inWorkspace: other.workspace).first { $0 != other.tab },
            "no tab beyond \(other.workspace)'s own exists; \(after.outline())"
        )
        let migrated = after.paneIDs(inTab: landed)
        let first = try XCTUnwrap(after.paneRect(migrated[0]), "\(migrated[0]) has no rect in any layout")
        let second = try XCTUnwrap(after.paneRect(migrated[1]), "\(migrated[1]) has no rect in any layout")
        XCTAssertEqual(
            first.y, second.y,
            "the source tab split right, so the replayed pair must be level, got y=\(first.y) and y=\(second.y)"
        )
        XCTAssertEqual(
            first.x + first.width, second.x,
            "the replayed pair does not sit side by side, got \(first) and \(second)"
        )
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabB],
            "the migrated tab is still in the workspace it left; \(after.outline())"
        )
        XCTAssertFalse(
            after.allPaneIDs().contains(ids.p1) || after.allPaneIDs().contains(ids.p2),
            "panes carried across workspaces are re-keyed, so neither \(ids.p1) nor \(ids.p2) may still exist; \(after.outline())"
        )

        assertCanvasMirrorsHerdr(app, "after a whole tab was carried into \(other.workspace)")
    }

    /// The root divider dragged to the middle of the right pane puts the
    /// boundary there: three quarters of the way across the pair. The
    /// expected ratio is derived from the boxes the window itself drew, so
    /// nothing here assumes a window size.
    @MainActor
    func testDraggingTheRootDividerWidensTheLeftPane() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        let before = app.flockBoxes(prefix: "flock.canvas.pane.")
        let left = try XCTUnwrap(before[canvasPane(ids.p1)], "the canvas is not drawing \(ids.p1)")
        let right = try XCTUnwrap(before[canvasPane(ids.p2)], "the canvas is not drawing \(ids.p2)")
        // The split's own region runs from the outer edge of one box to the
        // outer edge of the other, plus the gutter each box is inset by; that
        // inset is single points against a canvas hundreds wide, and the
        // tolerance below is wider than it.
        let expected = (right.midX - left.minX) / (right.maxX - left.minX)
        let seededRatio = try XCTUnwrap(
            session.snapshot().layoutRatio(tab: ids.tabA), "\(ids.tabA) carries no split to move"
        )
        XCTAssertEqual(seededRatio, 0.5, accuracy: 0.01, "this case reads a move away from the seed's even split")

        let trace = dragElement(
            app, fromID: "flock.canvas.divider.root", grabbing: .middle,
            toID: canvasPane(ids.p2), aiming: .middle
        )

        let after = try session.snapshot(waitingFor: "\(ids.tabA)'s split to move off 0.5. \(trace)") {
            guard let ratio = $0.layoutRatio(tab: ids.tabA) else { return false }
            return abs(ratio - 0.5) > 0.05
        }
        XCTAssertEqual(
            try XCTUnwrap(after.layoutRatio(tab: ids.tabA)), Double(expected), accuracy: 0.02,
            "the ratio herdr kept is not the one the pointer was released at; \(after.outline())"
        )
        let movedLeft = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let movedRight = try XCTUnwrap(after.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        XCTAssertGreaterThan(
            movedLeft.width, movedRight.width,
            "a divider dragged right must leave the left pane the wider of the two, got \(movedLeft) and \(movedRight)"
        )

        assertEventually("the canvas redraws \(ids.p1) wider than it was") {
            guard let now = app.flockBoxes(prefix: "flock.canvas.pane.")[self.canvasPane(ids.p1)] else { return false }
            return now.width > left.width + 1
        } describing: {
            let now = app.flockBoxes(prefix: "flock.canvas.pane.")[self.canvasPane(ids.p1)]
            return "\(ids.p1) was \(left), and is now \(now.map { "\($0)" } ?? "not drawn at all")"
        }
    }

    // MARK: - Editing the chrome

    /// Double-click opens the inline editor on the thing double-clicked, and
    /// Return commits what was typed into it.
    @MainActor
    func testDoubleClickingATabOpensTheEditorAndReturnRenamesIt() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        doubleClickElement(app, stripTab(ids.tabB))
        waitForEditor(app, "flock.strip.rename.\(ids.tabB)", on: stripTab(ids.tabB))

        // The editor selects its whole name as it opens, so this replaces
        // rather than appends.
        app.typeText("renamed\n")
        assertReachedTheEditor("renamed", notThePane: ids.p1, app: app, editor: "flock.strip.rename.\(ids.tabB)")

        let after = try snapshot(app, waitingFor: "\(ids.tabB) to be renamed", showing: ids.p1) {
            $0.label(ofTab: ids.tabB) == "renamed"
        }
        XCTAssertEqual(
            after.label(ofTab: ids.tabA), "1",
            "the rename reached a tab it was not opened on; \(after.outline())"
        )
        assertShows(app, "renamed", in: stripTab(ids.tabB), "the strip is not drawing the committed name")
        assertEventually("the editor closes on commit") {
            !app.flockElement("flock.strip.rename.\(ids.tabB)").exists
        } describing: {
            "the rename editor for \(ids.tabB) is still open"
        }
    }

    /// Escape discards the edit, and the label it was opened on is untouched
    /// on both sides.
    @MainActor
    func testEscapeLeavesATabsNameAsItWas() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        doubleClickElement(app, stripTab(ids.tabB))
        waitForEditor(app, "flock.strip.rename.\(ids.tabB)", on: stripTab(ids.tabB))
        app.typeText("discarded")
        assertReachedTheEditor("discarded", notThePane: ids.p1, app: app, editor: "flock.strip.rename.\(ids.tabB)")
        // The positive half, which only this case can take: its editor is
        // still open, so what the field holds says the keystrokes arrived
        // rather than merely that the terminal did not get them.
        assertShows(
            app, "discarded", in: "flock.strip.rename.\(ids.tabB)",
            "the editor is not showing what was typed into it"
        )
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        assertEventually("the editor closes on Escape") {
            !app.flockElement("flock.strip.rename.\(ids.tabB)").exists
        } describing: {
            "the rename editor for \(ids.tabB) is still open, so the Escape never reached it. "
                + "\(ids.p1) has on screen:\n\((try? self.session.paneText(ids.p1)) ?? "<pane.read answered nothing>")"
        }
        // Held, not sampled: a commit a cancel wrongly issued would reach
        // herdr a moment after the editor closed, and a single read taken
        // then would miss it.
        try assertStaysTrue("the name \(ids.tabB) had", for: 3) {
            try self.session.snapshot().label(ofTab: ids.tabB) == "tabB"
        }
        assertShows(app, "tabB", in: stripTab(ids.tabB), "the strip is not drawing the name the cancel kept")
    }

    /// A click into the focused pane's body is the other way out of an open
    /// editor, and the one path the focus rules deliberately leave alone: the
    /// terminal takes first responder directly, the field commits what it
    /// holds as it loses focus, and the keyboard stays where the click put it.
    ///
    /// The last part is not decoration. The editor's own claim re-asks on
    /// every pass it is given, so a render landing between the click and
    /// `commitRename` clearing the target could take the keyboard straight
    /// back off the pane the user just clicked, and nothing but a keystroke
    /// afterwards can tell.
    @MainActor
    func testClickingTheFocusedPaneCommitsTheOpenEditorAndKeepsTheKeyboard() throws {
        let ids = session.seedIDs()
        let seeded = try session.snapshot()
        XCTAssertEqual(seeded.focusedPaneID, ids.p1, "this case clicks the focused pane; \(seeded.outline())")
        let app = try launchOnSeed()

        doubleClickElement(app, stripTab(ids.tabB))
        waitForEditor(app, "flock.strip.rename.\(ids.tabB)", on: stripTab(ids.tabB))
        app.typeText("clicked-away")

        // The focused pane, not its sibling: an UNFOCUSED pane's body click
        // only asks herdr to move focus (`GhosttySurfaceView.mouseDown`), and
        // takes no first responder to dismiss anything with.
        clickElement(app, canvasPane(ids.p1), at: .middle)

        let after = try snapshot(app, waitingFor: "the click to commit the open edit", showing: ids.p1) {
            $0.label(ofTab: ids.tabB) == "clicked-away"
        }
        XCTAssertEqual(
            after.focusedPaneID, ids.p1,
            "the click moved herdr's focus off the pane it landed in; \(after.outline())"
        )
        assertEventually("the editor closes when the click commits it") {
            !app.flockElement("flock.strip.rename.\(ids.tabB)").exists
        } describing: {
            "the rename editor for \(ids.tabB) is still open after a click into a pane"
        }

        let marker = "flock-e2e-\(UUID().uuidString.prefix(8))"
        app.typeText("echo \(marker)\n")
        var typed = ""
        assertEventually("\(ids.p1) takes the keystrokes after the click that dismissed the editor", timeout: 30) {
            typed = (try? self.session.paneText(ids.p1)) ?? ""
            return typed.components(separatedBy: marker).count > 2
        } describing: {
            "the keyboard is neither on \(ids.p1) nor anywhere that shows. \(ids.p1) holds:\n\(typed)"
        }
    }

    /// The hover-revealed close on a tab and on a rail row. Neither is
    /// laid out into existence by the hover -- both are always there -- but
    /// neither takes a click until the row under the pointer reveals it,
    /// which is why the pointer is parked first and the control waited for.
    @MainActor
    func testTheHoverRevealedCloseDropsATabAndThenAWorkspace() throws {
        let ids = session.seedIDs()
        let other = try makeWorkspace(label: "other")
        let app = try launchOnSeed()
        waitForRailRows(app, [ids.ws, other.workspace])

        hoverElement(app, stripTab(ids.tabB))
        waitForControl(app, "flock.strip.close.\(ids.tabB)", revealedBy: stripTab(ids.tabB))
        clickElement(app, "flock.strip.close.\(ids.tabB)")

        let closedTab = try session.snapshot(waitingFor: "\(ids.tabB) to close") {
            $0.tabIDs(inWorkspace: ids.ws) == [ids.tabA]
        }
        XCTAssertFalse(
            closedTab.allPaneIDs().contains(ids.p3),
            "the tab's own pane outlived it; \(closedTab.outline())"
        )
        assertEventually("the strip drops the closed tab") {
            app.flockIdentifiers(prefix: "flock.strip.tab.") == [self.stripTab(ids.tabA)]
        } describing: {
            "the strip holds \(app.flockIdentifiers(prefix: "flock.strip.tab.").joined(separator: ", "))"
        }

        hoverElement(app, railRow(other.workspace))
        waitForControl(app, "flock.rail.close.\(other.workspace)", revealedBy: railRow(other.workspace))
        clickElement(app, "flock.rail.close.\(other.workspace)")

        let closedWorkspace = try session.snapshot(waitingFor: "\(other.workspace) to close") {
            $0.orderedWorkspaceIDs() == [ids.ws]
        }
        XCTAssertEqual(
            closedWorkspace.tabIDs(inWorkspace: ids.ws), [ids.tabA],
            "closing a workspace took something from the one beside it; \(closedWorkspace.outline())"
        )
        assertEventually("the rail drops the closed workspace") {
            app.flockIdentifiers(prefix: "flock.rail.workspace.") == [self.railRow(ids.ws)]
        } describing: {
            "the rail holds \(app.flockIdentifiers(prefix: "flock.rail.workspace.").joined(separator: ", "))"
        }
    }

    /// herdr refuses a plain close on a workspace that is a worktree group's
    /// primary, and flock turns that refusal into a question. Confirming it
    /// re-asks with the group included, which closes both workspaces at once.
    @MainActor
    func testTheGroupClosePromptClosesBothWorkspacesAtOnce() throws {
        let ids = session.seedIDs()
        let group = try session.seedWorktreeGroup()
        // herdr focuses a workspace it has just made, and the app comes up on
        // whatever herdr is focused on.
        try focusSeed()
        let app = try launchOnSeed()
        waitForRailRows(app, [ids.ws, group.primary, group.linked])

        hoverElement(app, railRow(group.primary))
        waitForControl(app, "flock.rail.close.\(group.primary)", revealedBy: railRow(group.primary))
        clickElement(app, "flock.rail.close.\(group.primary)")

        assertEventually("the group-close prompt appears") {
            app.flockElement("flock.workspace.closeGroup.confirm").exists
        } describing: {
            "the window is showing [\(app.flockIdentifiers(prefix: "flock.").joined(separator: ", "))]"
        }
        XCTAssertEqual(
            try session.snapshot().workspaceCount, 3,
            "the prompt is a question, so nothing may have closed while it is up"
        )

        clickElement(app, "flock.workspace.closeGroup.confirm")

        let after = try session.snapshot(waitingFor: "both group workspaces to close") {
            $0.orderedWorkspaceIDs() == [ids.ws]
        }
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "the group close took the seed's tabs with it; \(after.outline())"
        )
        assertEventually("the rail drops both group rows") {
            app.flockIdentifiers(prefix: "flock.rail.workspace.") == [self.railRow(ids.ws)]
        } describing: {
            "the rail holds \(app.flockIdentifiers(prefix: "flock.rail.workspace.").joined(separator: ", "))"
        }
    }

    // MARK: - The pane menu

    /// Split Right makes a real pane, and Close Pane takes one away.
    ///
    /// The close is aimed at the pane the split came off rather than at the
    /// pane it made: a pane flock created draws the harness launcher, and
    /// while that is up its surface claims no point at all
    /// (`GhosttySurfaceView.hitTest`), so there is no menu to right-click
    /// into on the new pane until something has been typed in it.
    @MainActor
    func testThePaneMenuSplitsRightAndThenClosesAPane() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        openPaneMenu(app, on: ids.p2)
        clickMenuItem(app, "flock.pane.menu.splitRight")

        let split = try session.snapshot(waitingFor: "a third pane in \(ids.tabA)") {
            $0.paneIDs(inTab: ids.tabA).count == 3
        }
        let made = try XCTUnwrap(
            split.paneIDs(inTab: ids.tabA).first { $0 != ids.p1 && $0 != ids.p2 },
            "no pane beyond the seed's two exists; \(split.outline())"
        )
        let anchor = try XCTUnwrap(split.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        let fresh = try XCTUnwrap(split.paneRect(made), "\(made) has no rect in any layout")
        XCTAssertGreaterThan(
            fresh.x, anchor.x,
            "Split Right must put the new pane right of the one the menu was opened on, got \(fresh) and \(anchor)"
        )
        assertCanvasHolds(app, [ids.p1, ids.p2, made], "after Split Right on \(ids.p2)")

        openPaneMenu(app, on: ids.p2)
        clickMenuItem(app, "flock.pane.menu.closePane")

        let closed = try session.snapshot(waitingFor: "\(ids.p2) to close") {
            $0.paneIDs(inTab: ids.tabA).sorted() == [ids.p1, made].sorted()
        }
        XCTAssertEqual(
            closed.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "closing a pane took a tab with it; \(closed.outline())"
        )
        assertCanvasHolds(app, [ids.p1, made], "after \(ids.p2) was closed from its own menu")
    }

    /// The Zoom row is flock's zoom affordance, and a zoom is something the
    /// window has to SHOW: herdr's renderer holds one pane of a zoomed tab
    /// open over the whole tab area, so flock's canvas draws that pane alone,
    /// filling the canvas, with the badge on it. herdr's own layout keeps
    /// listing every pane of the tab throughout -- that is what makes the
    /// canvas check the real one -- and using the row again brings the others
    /// back where they were.
    @MainActor
    func testTheZoomRowZoomsTheTabAndTogglesItBack() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        assertCanvasHolds(app, [ids.p1, ids.p2], "the seeded tab draws both its panes")
        let tiled = settledCanvasBoxes(app, panes: [ids.p1, ids.p2], "the seeded canvas settles on its boxes")
        let left = try XCTUnwrap(tiled[canvasPane(ids.p1)], "the canvas is not drawing \(ids.p1)")
        let right = try XCTUnwrap(tiled[canvasPane(ids.p2)], "the canvas is not drawing \(ids.p2)")
        // Both boxes are inset from their own layout frame by the same gutter
        // halves, so the two together span exactly what one pane holding the
        // whole tab area spans: the canvas, with nothing assumed about the
        // window's size.
        let wholeCanvas = left.union(right)

        openPaneMenu(app, on: ids.p2)
        clickMenuItem(app, "flock.pane.menu.zoom")

        let zoomed = try session.snapshot(waitingFor: "\(ids.tabA) to read as zoomed") { $0.isZoomed(tab: ids.tabA) }
        let badged = try XCTUnwrap(
            zoomed.focusedPaneID(inTab: ids.tabA),
            "\(ids.tabA)'s layout names no focused pane, so nothing says which pane the zoom holds open; \(zoomed.outline())"
        )
        XCTAssertEqual(
            zoomed.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2],
            "a zoom moves no pane; \(zoomed.outline())"
        )
        assertCanvasHolds(app, [badged], "the zoomed tab draws \(badged) and no other pane")
        assertCanvasPaneBox(app, badged, matches: wholeCanvas, "\(badged) fills the canvas while the tab is zoomed")
        assertEventually("the window marks \(badged) zoomed") {
            app.flockElement("flock.pane.zoomBadge.\(badged)").exists
        } describing: {
            "no zoom badge is drawn; the canvas holds "
                + "[\(app.flockIdentifiers(prefix: "flock.pane.").joined(separator: ", "))]"
        }

        openPaneMenu(app, on: badged)
        clickMenuItem(app, "flock.pane.menu.zoom")

        let unzoomed = try session.snapshot(waitingFor: "\(ids.tabA) to read as unzoomed") { !$0.isZoomed(tab: ids.tabA) }
        XCTAssertEqual(
            unzoomed.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2],
            "unzooming moved a pane; \(unzoomed.outline())"
        )
        assertCanvasHolds(app, [ids.p1, ids.p2], "unzooming brings the tab's other pane back")
        assertCanvasPaneBox(app, ids.p1, matches: left, "\(ids.p1) is back in the box it had before the zoom")
        assertCanvasPaneBox(app, ids.p2, matches: right, "\(ids.p2) is back in the box it had before the zoom")
        assertEventually("the window drops the zoom badge") {
            !app.flockElement("flock.pane.zoomBadge.\(badged)").exists
        } describing: {
            "the badge for \(badged) is still drawn"
        }
    }

    /// "Move to..." is the keyboard and accessibility route to every drop a
    /// drag can make, through the same planner. Aimed at another tab, it
    /// lands exactly where a drop on that tab's handle lands: split right of
    /// that tab's focused pane.
    @MainActor
    func testMoveToPutsThePaneInTheTabTheMenuNamed() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        openPaneMenu(app, on: ids.p2)
        hoverMenuItem(app, "flock.pane.menu.moveTo")
        clickMenuItem(app, "flock.pane.menu.moveTo.tab.\(ids.tabB)")

        let after = try session.snapshot(waitingFor: "\(ids.p2) to join \(ids.tabB)") {
            $0.tabID(ofPane: ids.p2) == ids.tabB
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB).sorted(), [ids.p2, ids.p3].sorted(),
            "\(ids.tabB) should hold the moved pane beside its own; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p1],
            "the pane should have left \(ids.tabA); \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertGreaterThan(
            moved.x, anchor.x,
            "a move into a tab splits RIGHT of that tab's focused pane, got \(moved) and \(anchor)"
        )

        assertCanvasMirrorsHerdr(app, "after \(ids.p2) was moved into \(ids.tabB) from the menu")
    }

    // MARK: - Focus and input

    /// A click on an unfocused pane moves herdr's focus to it, and the
    /// keystrokes after that go to THAT pane and to no other.
    @MainActor
    func testClickingAPaneFocusesItAndTypingReachesThatPaneAlone() throws {
        let ids = session.seedIDs()
        let seeded = try session.snapshot()
        XCTAssertEqual(
            seeded.focusedPaneID, ids.p1,
            "this case needs the seed's focus somewhere other than \(ids.p2); \(seeded.outline())"
        )
        let app = try launchOnSeed()

        // The cell's middle is the terminal body: its top band is the drag
        // handle, and a click there would grab rather than focus.
        clickElement(app, canvasPane(ids.p2), at: .middle)

        let focused = try session.snapshot(waitingFor: "herdr to focus \(ids.p2)") { $0.focusedPaneID == ids.p2 }
        XCTAssertEqual(
            focused.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2],
            "a focus click moved a pane; \(focused.outline())"
        )

        let marker = "flock-e2e-\(UUID().uuidString.prefix(8))"
        app.typeText("echo \(marker)\n")

        var typed = ""
        assertEventually("\(ids.p2) shows what was typed into it", timeout: 30) {
            typed = (try? self.session.paneText(ids.p2)) ?? ""
            // Twice over: the command line the keystrokes drew, and the line
            // the shell echoed back. One occurrence is a command that was
            // typed but never ran.
            return typed.components(separatedBy: marker).count > 2
        } describing: {
            "\(ids.p2) holds:\n\(typed)"
        }
        XCTAssertFalse(
            try session.paneText(ids.p1).contains(marker),
            "the keystrokes reached \(ids.p1) as well, so they went to the window rather than to the focused pane"
        )
    }

    /// A pane that goes blocked in a workspace nobody is looking at raises a
    /// toast, and the toast is a jump: it focuses that workspace, its tab and
    /// its pane, and the window follows all three.
    @MainActor
    func testABlockedPaneRaisesAToastThatJumpsToItsWorkspace() throws {
        let ids = session.seedIDs()
        let other = try makeWorkspace(label: "other")
        let app = try launchOnSeed()
        waitForRailRows(app, [ids.ws, other.workspace])

        // Reported only once the app is up: a toast is raised for a
        // TRANSITION, so a pane already blocked when the first snapshot
        // arrives says nothing.
        try session.mutate(
            #"{"id":"e2e-blocked","method":"pane.report_agent","params":{"pane_id":"\#(other.pane)","source":"flock-e2e","agent":"flock-e2e","state":"blocked"}}"#
        )

        let toast = "flock.attention.toast.\(other.pane)"
        assertEventually("a toast for \(other.pane) appears", timeout: 30) {
            app.flockElement(toast).exists
        } describing: {
            "the window is showing [\(app.flockIdentifiers(prefix: "flock.").joined(separator: ", "))]"
        }
        XCTAssertEqual(
            try session.snapshot().focusedWorkspaceID, ids.ws,
            "a toast must not move focus on its own; only the click below may"
        )

        clickElement(app, toast)

        let jumped = try session.snapshot(waitingFor: "the jump to reach \(other.pane)", timeout: 30) {
            $0.focusedWorkspaceID == other.workspace && $0.focusedTabID == other.tab && $0.focusedPaneID == other.pane
        }
        XCTAssertEqual(
            jumped.paneIDs(inTab: other.tab), [other.pane],
            "the jump changed the workspace it jumped to; \(jumped.outline())"
        )
        assertCanvasHolds(app, [other.pane], "after the toast jumped to \(other.workspace)")
        assertEventually("the toast is withdrawn once its pane is the focused one") {
            !app.flockElement(toast).exists
        } describing: {
            "the toast for \(other.pane) is still up after the jump"
        }
    }

    // MARK: - Undo

    /// Undo of a drop puts the session back exactly as it was: not only the
    /// pane's tab, but the split shape and the side of it the pane sat on.
    /// The comparison ignores only what moves on its own (a pane's revision,
    /// its scroll, the terminal id a reseed mints).
    @MainActor
    func testUndoOfADropPutsTheSessionBackExactlyAsItWas() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        // After the launch, never before it: attaching a pane resizes its
        // terminal, which moves every rect in the layout.
        let before = try settledSnapshot()

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: stripTab(ids.tabB), aiming: .middle)
        let dropped = try session.snapshot(waitingFor: "\(ids.p1) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p1) == ids.tabB
        }
        XCTAssertNotNil(
            before.difference(from: dropped),
            "the drop this case undoes changed nothing, so the undo below would prove nothing"
        )
        // Waited for before the keystroke, not only for its own sake: the Edit
        // menu disables Undo for the width of any step still in the journal's
        // chain, and the pane moved off the tab the window was showing, so the
        // canvas following it there is what says the drop has finished.
        assertCanvasHolds(app, [ids.p3, ids.p1], "after the drop this case undoes")

        app.typeKey("z", modifierFlags: .command)

        var difference: String?
        assertEventually("the session to match the one the drop started from", timeout: 30) {
            guard let now = try? self.session.snapshot() else { return false }
            difference = now.difference(from: before)
            return difference == nil
        } describing: {
            "herdr still differs at \(difference ?? "<no snapshot answered>")"
        }

        assertCanvasHolds(app, [ids.p1, ids.p2], "after the drop was undone")
        assertDrawnOrder(
            app, prefix: "flock.canvas.pane.", along: .x,
            expected: [canvasPane(ids.p1), canvasPane(ids.p2)],
            "the canvas did not redraw the pair in the order undo restored"
        )
    }

    // MARK: - Convergence

    /// Two changes made behind the app's back, with no interaction at all:
    /// the window has to show both.
    ///
    /// The one case in this suite that the event stream alone can pass. The
    /// wrapper gives every other case a two-second re-snapshot, under which a
    /// window whose subscription was entirely dead would still catch up by
    /// polling and every wait here would still be satisfied; this one pushes
    /// that backstop past any wait it can make, so what arrives can only have
    /// arrived as an event.
    @MainActor
    func testARenameAndASplitMadeElsewhereBothAppear() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed(env: ["FLOCK_RESNAPSHOT_SECONDS": Self.noResnapshotWithin])

        try session.mutate(
            #"{"id":"e2e-rename","method":"tab.rename","params":{"tab_id":"\#(ids.tabA)","label":"elsewhere"}}"#
        )
        try session.mutate(
            #"{"id":"e2e-split","method":"pane.split","params":{"target_pane_id":"\#(ids.p2)","direction":"down"}}"#
        )

        let after = try session.snapshot(waitingFor: "both changes to land in herdr") {
            $0.label(ofTab: ids.tabA) == "elsewhere" && $0.paneIDs(inTab: ids.tabA).count == 3
        }
        let added = try XCTUnwrap(
            after.paneIDs(inTab: ids.tabA).first { $0 != ids.p1 && $0 != ids.p2 },
            "the split never landed; \(after.outline())"
        )

        assertCanvasHolds(app, [ids.p1, ids.p2, added], "after a split made outside the app")
        assertShows(app, "elsewhere", in: stripTab(ids.tabA), "the strip is not drawing the name herdr now holds")
    }

    /// A thousand renames as fast as the bridge will carry them, which is
    /// several times the depth of the server's own event ring.
    ///
    /// What it proves is that the window ends on the last label and the app
    /// is still answering: it does NOT distinguish the two ways it can get
    /// there, since nothing in `HerdrStore` reports a gap -- the events are
    /// applied one by one, and the periodic re-snapshot replaces the model
    /// whether or not any were dropped. The wait is wider than the wrapper's
    /// own two-second re-snapshot for that reason, so this is a convergence
    /// claim and not a delivery one; the brief's five seconds would have read
    /// as the latter.
    @MainActor
    func testAThousandRenamesLeaveTheWindowOnTheLastLabel() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        let last = "burst-1000"
        for index in 1...1000 {
            try session.mutate(
                #"{"id":"e2e-burst-\#(index)","method":"tab.rename","params":{"tab_id":"\#(ids.tabB)","label":"burst-\#(index)"}}"#
            )
        }

        let after = try session.snapshot(waitingFor: "the last of the burst to land in herdr") {
            $0.label(ofTab: ids.tabB) == last
        }
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "a burst of renames changed the strip's contents; \(after.outline())"
        )
        assertShows(app, last, in: stripTab(ids.tabB), "the window did not converge on the last label of the burst", timeout: 30)
        assertCanvasHolds(app, [ids.p1, ids.p2], "after a burst of a thousand renames")
    }

    /// The server goes away and comes back on the same session directory. The
    /// app has to return to live, which is asserted by a change made AFTER
    /// the restart: what it was already drawing would still be on screen if
    /// it had never reconnected at all.
    ///
    /// Re-subscribed is more than this can say. A reconnected socket carries
    /// the wrapper's own two-second re-snapshot as well as the event stream,
    /// and either draws the new tab, so what is proven is that the app
    /// reconnected -- not which of the two told it.
    @MainActor
    func testTheAppComesBackAfterTheServerRestarts() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        try session.restartServer()

        let restored = try session.snapshot()
        XCTAssertEqual(
            restored.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2],
            "the restart did not bring the session back as it was; \(restored.outline())"
        )

        try session.mutate(
            #"{"id":"e2e-after","method":"tab.create","params":{"workspace_id":"\#(ids.ws)","label":"afterwards"}}"#
        )
        let after = try session.snapshot(waitingFor: "a third tab after the restart") {
            $0.tabCount(inWorkspace: ids.ws) == 3
        }
        let made = try XCTUnwrap(
            after.tabIDs(inWorkspace: ids.ws).first { $0 != ids.tabA && $0 != ids.tabB },
            "the tab this case watches for never landed; \(after.outline())"
        )

        assertEventually("the strip draws the tab made after the restart", timeout: 60) {
            app.flockElement(self.stripTab(made)).exists
        } describing: {
            "the strip holds [\(app.flockIdentifiers(prefix: "flock.strip.tab.").joined(separator: ", "))], "
                + "so the app never re-subscribed"
        }
        assertCanvasHolds(app, [ids.p1, ids.p2], "after the server restarted under the app")
    }

    // MARK: - Fixtures

    private enum Axis {
        case x
        case y
    }

    private func canvasPane(_ paneID: String) -> String { "flock.canvas.pane.\(paneID)" }

    private func stripTab(_ tabID: String) -> String { "flock.strip.tab.\(tabID)" }

    private func railRow(_ workspaceID: String) -> String { "flock.rail.workspace.\(workspaceID)" }

    /// Puts herdr's focus back on the seed workspace, which is where the app
    /// comes up and what every case below starts from.
    private func focusSeed() throws {
        let ids = session.seedIDs()
        try session.mutate(#"{"id":"e2e-back","method":"workspace.focus","params":{"workspace_id":"\#(ids.ws)"}}"#)
        _ = try session.snapshot(waitingFor: "the seed workspace to be focused") { $0.focusedWorkspaceID == ids.ws }
    }

    /// A workspace made through herdr rather than through the app, with the
    /// seed left focused.
    private func makeWorkspace(label: String) throws -> (workspace: String, tab: String, pane: String) {
        let ids = session.seedIDs()
        let known = Set(try session.snapshot().orderedWorkspaceIDs())
        try session.mutate(
            #"{"id":"e2e-ws","method":"workspace.create","params":{"cwd":"/tmp","label":"\#(label)"}}"#
        )
        try focusSeed()
        let seeded = try session.snapshot(waitingFor: "a workspace labelled \(label), with the seed focused") {
            $0.orderedWorkspaceIDs().count == known.count + 1 && $0.focusedWorkspaceID == ids.ws
        }
        let made = try XCTUnwrap(
            seeded.orderedWorkspaceIDs().first { !known.contains($0) }, "the workspace \(label) was never made"
        )
        let tab = try XCTUnwrap(seeded.tabIDs(inWorkspace: made).first, "\(made) holds no tab; \(seeded.outline())")
        let pane = try XCTUnwrap(seeded.paneIDs(inTab: tab).first, "\(tab) holds no pane; \(seeded.outline())")
        return (made, tab, pane)
    }

    /// The same wait as `ScratchSession.snapshot(waitingFor:until:)`, with
    /// the window's notice slot watched alongside herdr.
    ///
    /// A gesture the app never acted on and a gesture the app acted on and
    /// reported as refused or half-landed leave herdr looking identical. The
    /// difference is the toast: `SessionViewModel.perform` raises "Can't move
    /// there" for a plan it refuses and "<label> failed: <message>" for one
    /// that broke partway. It lives about two and a half seconds, so it is
    /// read on the same beat as herdr rather than after.
    /// `showing` names a pane whose screen is printed with the timeout. Where
    /// keystrokes went is not a thing the window can be asked, so the shell
    /// echoing them is the artifact, and a failure that only says "the rename
    /// never arrived" makes the reader take that on trust.
    @MainActor
    private func snapshot(
        _ app: XCUIApplication, waitingFor expectation: String, timeout: TimeInterval = 20,
        showing paneID: String? = nil,
        until condition: (HerdrSnapshotJSON) -> Bool
    ) throws -> HerdrSnapshotJSON {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: HerdrSnapshotJSON?
        var notices: [String] = []
        repeat {
            let current = try session.snapshot()
            latest = current
            if condition(current) { return current }
            for line in app.flockText(inAnyOf: ["flock.toast.info", "flock.toast.notice"])
            where !notices.contains(line) {
                notices.append(line)
            }
            usleep(200_000)
        } while Date() < deadline
        let focus = latest.map {
            "focus \($0.focusedWorkspaceID ?? "?")/\($0.focusedTabID ?? "?")/\($0.focusedPaneID ?? "?")"
        } ?? "no focus"
        let screen = paneID.map { pane in
            "\n\(pane) has on screen:\n\((try? session.paneText(pane)) ?? "<pane.read answered nothing>")"
        } ?? ""
        throw ScratchSessionError(
            "timed out after \(timeout)s waiting for \(expectation). herdr holds: "
                + (latest?.outline() ?? "<no snapshot answered>") + " (\(focus))"
                + ". The window "
                + (notices.isEmpty ? "raised no notice, so the app believes it did what was asked" : "said: \(notices.joined(separator: " | "))")
                + screen
        )
    }

    /// Checks a claim about herdr repeatedly over a window rather than once,
    /// for the cases that assert something did NOT happen: the call that
    /// would disprove them is asynchronous, and a single read can be taken
    /// before it lands.
    private func assertStaysTrue(
        _ what: String, for seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () throws -> Bool
    ) rethrows {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if try !condition() {
                XCTFail("\(what) did not hold for \(seconds)s", file: file, line: line)
                return
            }
            usleep(250_000)
        } while Date() < deadline
    }

    /// A snapshot the session has stopped moving under: the app's own attach
    /// resizes every pane it draws, and a comparison against a snapshot taken
    /// mid-resize would report that rather than what the case did.
    private func settledSnapshot(timeout: TimeInterval = 30) throws -> HerdrSnapshotJSON {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = try session.snapshot()
        var difference: String?
        repeat {
            usleep(700_000)
            let current = try session.snapshot()
            difference = current.difference(from: previous)
            if difference == nil { return current }
            previous = current
        } while Date() < deadline
        throw ScratchSessionError(
            "the session never stopped changing on its own within \(timeout)s; last difference at \(difference ?? "<none>")"
        )
    }

    /// Longer than any case can run, for the one case that must not be able
    /// to pass on the re-snapshot backstop the wrapper gives every other.
    private static let noResnapshotWithin = "600"

    @MainActor
    private func launchOnSeed(env: [String: String] = [:]) throws -> XCUIApplication {
        let ids = session.seedIDs()
        // Registered before the launch that needs it, and capturing nothing:
        // an assertion failure under `continueAfterFailure = false` unwinds
        // this method through Objective-C, where a `defer` is not reliable,
        // and an app left attached to a session the wrapper is about to stop
        // outlives the whole run.
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.flock(socket: session.socketPath, env: env)
        XCTAssertTrue(
            app.flockElement(canvasPane(ids.p1)).waitForExistence(timeout: 60),
            "the canvas never drew \(ids.p1), so this case had nothing to work on"
        )
        XCTAssertTrue(
            app.flockElement(canvasPane(ids.p2)).waitForExistence(timeout: 30),
            "the canvas never drew \(ids.p2)"
        )
        return app
    }

    @MainActor
    private func waitForRailRows(_ app: XCUIApplication, _ workspaceIDs: [String]) {
        let wanted = Set(workspaceIDs.map { railRow($0) })
        assertEventually("the rail draws a row for every workspace herdr holds") {
            Set(app.flockIdentifiers(prefix: "flock.rail.workspace.")) == wanted
        } describing: {
            "the rail holds [\(app.flockIdentifiers(prefix: "flock.rail.workspace.").joined(separator: ", "))], "
                + "expected [\(wanted.sorted().joined(separator: ", "))]"
        }
    }

    /// Opens the pane menu with a right-click on the pane's body.
    ///
    /// `RightClickDisposition` sends a right-click to the pane's own program
    /// only when that pane is flock's focused one AND its program has
    /// claimed the mouse; every case here opens the menu on a plain shell,
    /// and most of them on a pane that is not the focused one, so the menu is
    /// what answers.
    @MainActor
    private func openPaneMenu(_ app: XCUIApplication, on paneID: String) {
        rightClickElement(app, canvasPane(paneID))
        assertEventually("the pane menu opens on \(paneID)") {
            app.menuItems.matching(identifier: "flock.pane.menu.splitRight").firstMatch.exists
        } describing: {
            "no pane menu is up: the app has \(app.menuItems.count) menu items in all, and is showing "
                + "[\(app.flockIdentifiers(prefix: "flock.pane.menu").joined(separator: ", "))]"
        }
    }

    @MainActor
    private func clickMenuItem(
        _ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let item = app.menuItems.matching(identifier: identifier).firstMatch
        XCTAssertTrue(
            item.waitForExistence(timeout: 10),
            "the open menu carries no \(identifier)", file: file, line: line
        )
        item.click()
    }

    /// A submenu opens under the pointer, so its parent is hovered rather
    /// than clicked: a click on a parent row can dismiss the menu it belongs
    /// to instead of opening what hangs off it.
    @MainActor
    private func hoverMenuItem(
        _ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let item = app.menuItems.matching(identifier: identifier).firstMatch
        XCTAssertTrue(
            item.waitForExistence(timeout: 10),
            "the open menu carries no \(identifier)", file: file, line: line
        )
        item.hover()
    }

    @MainActor
    private func waitForEditor(
        _ app: XCUIApplication, _ identifier: String, on host: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertEventually("the rename editor opens", file: file, line: line) {
            app.flockElement(identifier).exists
        } describing: {
            "no editor is open, so the keystrokes below would go to whatever has focus instead. "
                + "\(host) is drawing [\(app.flockText(in: host).joined(separator: " | "))]"
        }
    }

    /// Where the keystrokes actually went.
    ///
    /// An inline editor that does not hold keyboard focus is invisible from
    /// the outside: the window still draws it, and the keys go to whatever
    /// does hold focus, which in this window is the focused pane's terminal.
    /// There they are typed into a shell instead, so the pane's own screen is
    /// what says so. The editor's text is read from the same capture, since a
    /// field that took nothing is the other half of the same answer.
    @MainActor
    private func assertReachedTheEditor(
        _ typed: String, notThePane paneID: String, app: XCUIApplication, editor: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let screen = (try? session.paneText(paneID)) ?? ""
        guard screen.contains(typed) else { return }
        XCTFail(
            "\"\(typed)\" was typed into the terminal of \(paneID), so the rename editor did not have keyboard focus. "
                + "The editor is showing [\(app.flockText(in: editor).joined(separator: " | "))] and \(paneID) holds:\n\(screen)",
            file: file, line: line
        )
    }

    /// A hover-revealed control is laid out at all times and takes no click
    /// until its row reveals it, so its appearing in the tree is the signal
    /// that the hover landed.
    @MainActor
    private func waitForControl(
        _ app: XCUIApplication, _ identifier: String, revealedBy host: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertEventually("\(identifier) is revealed", file: file, line: line) {
            app.flockElement(identifier).exists
        } describing: {
            "hovering \(host) revealed nothing; the window is showing "
                + "[\(app.flockIdentifiers(prefix: "flock.").joined(separator: ", "))]"
        }
    }

    @MainActor
    private func assertCanvasHolds(
        _ app: XCUIApplication, _ paneIDs: [String], _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let wanted = Set(paneIDs.map { canvasPane($0) })
        assertEventually(what, file: file, line: line) {
            Set(app.flockIdentifiers(prefix: "flock.canvas.pane.")) == wanted
        } describing: {
            let seen = app.flockIdentifiers(prefix: "flock.canvas.pane.")
            return "the canvas holds [\(seen.joined(separator: ", "))], expected [\(wanted.sorted().joined(separator: ", "))]"
        }
    }

    /// The canvas's pane boxes once two consecutive reads agree on every pane
    /// named, each drawn and non-empty.
    ///
    /// A cell's identifier appears as soon as the cell exists, which is one or
    /// more layout passes before the window has finished sizing it, so a
    /// baseline taken from a single read right after the identifiers arrive can
    /// be short by whatever the last pass moved. Every comparison made against
    /// that baseline later inherits the error, and at a 1pt tolerance the
    /// failure reads as a zoom that put a pane in the wrong place.
    @MainActor
    private func settledCanvasBoxes(
        _ app: XCUIApplication, panes paneIDs: [String], _ what: String,
        timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line
    ) -> [String: CGRect] {
        let wanted = paneIDs.map { canvasPane($0) }
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [String: CGRect] = [:]
        var current: [String: CGRect] = [:]
        repeat {
            current = app.flockBoxes(prefix: "flock.canvas.pane.")
            let drawn = wanted.compactMap { current[$0] }
            if drawn.count == wanted.count, drawn.allSatisfy({ !$0.isEmpty }),
               wanted.allSatisfy({ previous[$0] == current[$0] }) {
                return current
            }
            previous = current
            usleep(200_000)
        } while Date() < deadline
        XCTFail(
            "\(what): the canvas never held \(wanted.joined(separator: ", ")) still for two reads. "
                + "The last read was [\(current.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))]",
            file: file, line: line
        )
        return current
    }

    /// A pane's drawn box, polled: a canvas that has just been told to redraw
    /// can be read one layout pass behind the one it is settling into. The
    /// tolerance is a point, which is under the single points a box is inset
    /// from its layout frame by and far under any real difference in where a
    /// pane landed.
    @MainActor
    private func assertCanvasPaneBox(
        _ app: XCUIApplication, _ paneID: String, matches expected: CGRect, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func drawn() -> CGRect? { app.flockBoxes(prefix: "flock.canvas.pane.")[canvasPane(paneID)] }
        func matches(_ box: CGRect) -> Bool {
            abs(box.minX - expected.minX) <= 1 && abs(box.minY - expected.minY) <= 1
                && abs(box.width - expected.width) <= 1 && abs(box.height - expected.height) <= 1
        }
        assertEventually(what, file: file, line: line) {
            drawn().map(matches) ?? false
        } describing: {
            "the canvas draws \(paneID) at \(drawn().map { "\($0)" } ?? "no box at all"), expected \(expected)"
        }
    }

    /// The canvas draws the panes of whatever tab herdr says is focused. The
    /// app follows herdr's focused tab (`SessionViewModel.update`), so this is
    /// the assertion for a case whose outcome decides for itself which tab
    /// that ends up being.
    @MainActor
    private func assertCanvasMirrorsHerdr(
        _ app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        func expected() -> Set<String>? {
            guard let truth = try? session.snapshot(), let tab = truth.focusedTabID else { return nil }
            return Set(truth.paneIDs(inTab: tab).map { canvasPane($0) })
        }
        assertEventually(what, file: file, line: line) {
            guard let wanted = expected() else { return false }
            return Set(app.flockIdentifiers(prefix: "flock.canvas.pane.")) == wanted
        } describing: {
            let seen = app.flockIdentifiers(prefix: "flock.canvas.pane.")
            let wanted = expected().map { $0.sorted().joined(separator: ", ") } ?? "<herdr answered nothing>"
            return "the canvas holds [\(seen.joined(separator: ", "))], and herdr's focused tab holds [\(wanted)]"
        }
    }

    /// The order the window actually draws a family of items in, read from
    /// ONE capture so the boxes compared are boxes it held at the same
    /// instant.
    @MainActor
    private func assertDrawnOrder(
        _ app: XCUIApplication, prefix: String, along axis: Axis, expected: [String], _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func drawn() -> [String] {
            let boxes = app.flockBoxes(prefix: prefix)
            return boxes.keys.sorted { left, right in
                guard let a = boxes[left], let b = boxes[right] else { return false }
                return axis == .x ? a.minX < b.minX : a.minY < b.minY
            }
        }
        assertEventually(what, file: file, line: line) {
            drawn() == expected
        } describing: {
            "the window draws [\(drawn().joined(separator: ", "))], expected [\(expected.joined(separator: ", "))]"
        }
    }

    @MainActor
    private func assertShows(
        _ app: XCUIApplication, _ text: String, in identifier: String, _ what: String,
        timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertEventually(what, timeout: timeout, file: file, line: line) {
            app.flockText(in: identifier).contains(text)
        } describing: {
            "\(identifier) is drawing [\(app.flockText(in: identifier).joined(separator: " | "))], expected \"\(text)\""
        }
    }
}
