import XCTest

/// Every pane drag the drop resolver can answer, driven as a real pointer
/// gesture against the running app and checked on both sides: what herdr ends
/// up holding, and what the window ends up drawing.
///
/// **Independence.** One herdr session serves a whole `xcodebuild test`
/// invocation, so `setUpWithError` reseeds it before every case and every case
/// launches its own app, terminated in a teardown block. Nothing here reads a
/// layout or a window another case left behind, and the cases may be run in
/// any order or one at a time.
///
/// **Where the canvas cannot host a case.** A pane-to-pane drop ACROSS tabs
/// cannot be driven on the canvas: `MainWindow` draws `viewModel.selectedLayout`,
/// which is one tab, so a pane of `tabA` and a pane of `tabB` are never both on
/// it. The All Workspaces grid is the one surface that draws two tabs' panes at
/// once, and `resolveThumbnail` sends a point inside a mini pane through the
/// canvas's own `resolveCanvas`, so the three cross-tab pane-target cases are
/// driven there and reach the same `GesturePlanner` verbs a canvas drop would.
/// The grid's mini panes carry no identifiers of their own, so those drags
/// state their points as fractions of the thumbnail that draws them, derived
/// from the thumbnail metrics named beside the fractions.
///
/// **Nothing may happen while a drag is in flight.** XCTest owns the machine
/// for the length of a gesture it started: it refuses to synthesize a key
/// until the gesture ends, it does not reliably turn the main run loop the
/// gesture blocks, and it hangs outright if the app under test stops being
/// frontmost. So every case here is one uninterrupted press-drag-release, and
/// what only an interrupted drag could show -- Escape cancelling one, a
/// spring-load reveal landing mid-drag -- is left to the unit tests that cover
/// those decisions.
final class PaneDragTests: XCTestCase {
    private var session: ScratchSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
    }

    // MARK: - Pane onto a pane of another tab (driven in the grid)

    /// A pane aimed at the right band of another tab's pane splits in beside
    /// it, on the right.
    @MainActor
    func testRightEdgeDropLandsThePaneRightOfAPaneOfAnotherTab() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        openGrid(app, ids: ids)

        let trace = dragElement(
            app,
            fromID: gridTab(ids.tabA), grabbing: Self.firstMiniPaneOfTwo,
            toID: gridTab(ids.tabB), aiming: .fraction(x: 1 - Self.miniPaneEdgeX, y: Self.miniPaneY)
        )

        let after = try session.snapshot(waitingFor: "\(ids.p1) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p1) == ids.tabB
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB).sorted(), [ids.p1, ids.p3].sorted(),
            "\(ids.tabB) should hold the moved pane beside its own; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA) entirely; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertGreaterThan(
            moved.x, anchor.x,
            "a right-edge drop puts the moved pane right of its target, got \(ids.p1) at x=\(moved.x) and \(ids.p3) at x=\(anchor.x)"
        )
        XCTAssertEqual(moved.y, anchor.y, "a right split leaves both panes level, got y=\(moved.y) and y=\(anchor.y)")

        showTabFromGrid(app, ids.tabB)
        assertCanvasHolds(app, [ids.p3, ids.p1], "after a right-edge drop into \(ids.tabB)")
        assertCellIsLeftOf(app, ids.p3, ids.p1, "the canvas draws the moved pane on the wrong side of its target")
    }

    /// The composition case: the left and top bands are the two that herdr's
    /// own `pane.move` cannot place directly, so the plan splits right and
    /// appends a swap. The moved pane ending on the LEFT is the whole point.
    @MainActor
    func testLeftEdgeDropComposesTheMovedPaneOntoTheLeft() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        openGrid(app, ids: ids)

        let trace = dragElement(
            app,
            fromID: gridTab(ids.tabA), grabbing: Self.firstMiniPaneOfTwo,
            toID: gridTab(ids.tabB), aiming: .fraction(x: Self.miniPaneEdgeX, y: Self.miniPaneY)
        )

        let after = try session.snapshot(waitingFor: "\(ids.p1) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p1) == ids.tabB
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB).sorted(), [ids.p1, ids.p3].sorted(),
            "\(ids.tabB) should hold the moved pane beside its own; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertLessThan(
            moved.x, anchor.x,
            "a left-edge drop splits right and then swaps, so the moved pane ends on the LEFT; "
                + "got \(ids.p1) at x=\(moved.x) and \(ids.p3) at x=\(anchor.x), which is the un-composed order"
        )

        showTabFromGrid(app, ids.tabB)
        assertCanvasHolds(app, [ids.p1, ids.p3], "after a left-edge drop into \(ids.tabB)")
        assertCellIsLeftOf(app, ids.p1, ids.p3, "the canvas did not draw the composed order")
    }

    /// The middle of another tab's pane takes the drop too, and lands the pane
    /// beside THAT pane. Driven with the second mini pane of the two-pane
    /// thumbnail, so the grab point is the other side of the same thumbnail
    /// the edge cases grab.
    @MainActor
    func testInteriorDropMovesThePaneIntoTheTabOfTheTargetPane() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        openGrid(app, ids: ids)

        let trace = dragElement(
            app,
            fromID: gridTab(ids.tabA), grabbing: Self.secondMiniPaneOfTwo,
            toID: gridTab(ids.tabB), aiming: .fraction(x: 0.5, y: Self.miniPaneY)
        )

        let after = try session.snapshot(waitingFor: "\(ids.p2) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p2) == ids.tabB
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB).sorted(), [ids.p2, ids.p3].sorted(),
            "\(ids.tabB) should hold the moved pane beside its own; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p1],
            "the pane should have left \(ids.tabA) entirely; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertGreaterThan(
            moved.x, anchor.x,
            "an interior drop splits right of the target pane, got \(ids.p2) at x=\(moved.x) and \(ids.p3) at x=\(anchor.x)"
        )

        showTabFromGrid(app, ids.tabB)
        assertCanvasHolds(app, [ids.p3, ids.p2], "after an interior drop into \(ids.tabB)")
    }

    // MARK: - Pane onto a pane of its own tab (driven on the canvas)

    /// Two panes of one tab exchange places and keep their ids: herdr refuses
    /// a same-tab `pane.move`, so this is the one drop that plans a swap.
    @MainActor
    func testInteriorDropSwapsTwoPanesOfTheSameTab() throws {
        let ids = session.seedIDs()
        let before = try session.snapshot()
        let leftBefore = try XCTUnwrap(before.paneRect(ids.p1), "\(ids.p1) has no rect in the seed")
        let rightBefore = try XCTUnwrap(before.paneRect(ids.p2), "\(ids.p2) has no rect in the seed")
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: canvasPane(ids.p2), aiming: .middle)

        let after = try session.snapshot(waitingFor: "\(ids.p1) and \(ids.p2) to exchange rects. \(trace)") {
            $0.paneRect(ids.p1) == rightBefore && $0.paneRect(ids.p2) == leftBefore
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA).sorted(), [ids.p1, ids.p2].sorted(),
            "a swap moves no pane out of its tab and re-keys neither; \(after.outline())"
        )
        XCTAssertEqual(
            after.tabCount(inWorkspace: ids.ws), 2,
            "a swap makes no tab; \(after.outline())"
        )

        assertCanvasHolds(app, [ids.p1, ids.p2], "after a same-tab interior swap")
        assertCellIsLeftOf(app, ids.p2, ids.p1, "the canvas did not redraw the swapped order")
    }

    /// The same-tab bounce: herdr refuses a same-tab move outright, so the
    /// plan parks the pane in a tab of its own, splits it back in, and closes
    /// the tab it made. The pane keeps its id and the temp tab must not
    /// survive.
    @MainActor
    func testBottomEdgeDropRestructuresTheTabAndLeavesNoTempTabBehind() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: canvasPane(ids.p2), aiming: .edge(.bottom))

        let after = try session.snapshot(waitingFor: "\(ids.tabA) to hold a down split. \(trace)") {
            $0.splitDirections(inTab: ids.tabA) == ["down"] && $0.tabCount(inWorkspace: ids.ws) == 2
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA).sorted(), [ids.p1, ids.p2].sorted(),
            "a same-workspace move keeps the pane's id, and the bounce must end with both panes back in \(ids.tabA); \(after.outline())"
        )
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "the tab the bounce parked the pane in was not closed; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        XCTAssertGreaterThan(
            moved.y, anchor.y,
            "a bottom-edge drop puts the moved pane below its target, got \(ids.p1) at y=\(moved.y) and \(ids.p2) at y=\(anchor.y)"
        )
        XCTAssertEqual(moved.x, anchor.x, "a down split leaves both panes on the same x, got \(moved.x) and \(anchor.x)")

        assertCanvasHolds(app, [ids.p1, ids.p2], "after a same-tab bottom-edge restructure")
        func stacked() -> (top: CGRect, bottom: CGRect)? {
            let drawn = app.paddockBoxes(prefix: Self.canvasPanePrefix)
            guard let top = drawn[canvasPane(ids.p2)], let bottom = drawn[canvasPane(ids.p1)] else { return nil }
            return (top, bottom)
        }
        assertEventually("the canvas draws \(ids.p1) below \(ids.p2)") {
            guard let pair = stacked() else { return false }
            return pair.top.maxY <= pair.bottom.minY + 1
        } describing: {
            guard let pair = stacked() else { return "the canvas is not drawing both \(ids.p1) and \(ids.p2)" }
            return "\(ids.p2) is at \(pair.top), \(ids.p1) at \(pair.bottom)"
        }
    }

    // MARK: - Pane onto the chrome

    /// The strip's free run past the last tab. Only a pane may use it, and it
    /// makes the tab it lands in.
    @MainActor
    func testDropOnTheStripsFreeRunMakesAThirdTab() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "paddock.strip.newTab", aiming: .edge(.right))

        let after = try session.snapshot(waitingFor: "a third tab in \(ids.ws). \(trace)") {
            $0.tabCount(inWorkspace: ids.ws) == 3
        }
        let made = try XCTUnwrap(
            after.tabIDs(inWorkspace: ids.ws).first { $0 != ids.tabA && $0 != ids.tabB },
            "no tab beyond the seed's two exists; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: made), [ids.p1],
            "the new tab should hold the dropped pane and nothing else; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA); \(after.outline())"
        )

        assertEventually("the strip draws three tabs") {
            app.paddockElementCount(identifierPrefix: "paddock.strip.tab.") == 3
        } describing: {
            "the strip holds \(app.paddockIdentifiers(prefix: "paddock.strip.tab.").joined(separator: ", "))"
        }
        // A pane moved off the tab the user is looking at is followed there,
        // so the canvas ends on the tab the drop made.
        assertCanvasHolds(app, [ids.p1], "after a drop on the strip's free run")
    }

    /// The rail's free run below the last row. A pane carried into a workspace
    /// that did not exist is re-keyed by herdr, and the window has to be
    /// drawing the new id, not the old one.
    @MainActor
    func testDropOnTheRailsFreeRunMakesAWorkspaceAndTheAppFollowsTheRekeyedPane() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "paddock.rail.newWorkspace", aiming: .edge(.bottom))

        let after = try session.snapshot(waitingFor: "a second workspace. \(trace)") { $0.workspaceCount == 2 }
        let made = try XCTUnwrap(
            after.orderedWorkspaceIDs().first { $0 != ids.ws },
            "no workspace beyond the seed's exists; \(after.outline())"
        )
        let madeTab = try XCTUnwrap(
            after.tabIDs(inWorkspace: made).first, "\(made) holds no tab; \(after.outline())"
        )
        let rekeyed = try XCTUnwrap(
            after.paneIDs(inTab: madeTab).first, "\(madeTab) holds no pane; \(after.outline())"
        )
        XCTAssertEqual(
            after.tabCount(inWorkspace: made), 1,
            "a pane carried into a new workspace makes it one tab; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: madeTab).count, 1,
            "the new workspace's tab should hold the dropped pane and nothing else; \(after.outline())"
        )
        XCTAssertNotEqual(
            rekeyed, ids.p1,
            "a pane carried across workspaces is re-keyed by herdr, so it must not still answer to \(ids.p1)"
        )
        XCTAssertFalse(
            after.allPaneIDs().contains(ids.p1),
            "\(ids.p1) still exists somewhere after being carried into \(made); \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA); \(after.outline())"
        )

        assertEventually("the rail draws two workspaces") {
            app.paddockElementCount(identifierPrefix: "paddock.rail.workspace.") == 2
        } describing: {
            "the rail holds \(app.paddockIdentifiers(prefix: "paddock.rail.workspace.").joined(separator: ", "))"
        }
        assertCanvasHolds(
            app, [rekeyed],
            "after a drop on the rail's free run the canvas must draw the id herdr assigned, not \(ids.p1)"
        )
    }

    /// A pane dropped on a tab's own handle in the strip goes into that tab
    /// with no pane named, which herdr resolves against that tab's focused
    /// pane, splitting right of it.
    @MainActor
    func testDropOnATabHandleSplitsRightOfThatTabsFocusedPane() throws {
        let ids = session.seedIDs()
        let seeded = try session.snapshot()
        XCTAssertEqual(
            seeded.paneIDs(inTab: ids.tabB), [ids.p3],
            "this case reads the split against \(ids.tabB)'s only pane; \(seeded.outline())"
        )
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "paddock.strip.tab.\(ids.tabB)", aiming: .middle)

        let after = try session.snapshot(waitingFor: "\(ids.p1) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p1) == ids.tabB
        }
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB).sorted(), [ids.p1, ids.p3].sorted(),
            "\(ids.tabB) should hold the moved pane beside its own; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA); \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertGreaterThan(
            moved.x, anchor.x,
            "a tab-handle drop splits RIGHT of that tab's focused pane, got \(ids.p1) at x=\(moved.x) and \(ids.p3) at x=\(anchor.x)"
        )

        // The pane left the tab the window was showing, so the app follows it.
        assertCanvasHolds(app, [ids.p3, ids.p1], "after a drop on \(ids.tabB)'s handle")
    }

    // MARK: - Guards

    /// herdr refuses a `pane.move` out of a zoomed tab (`zoomed_tab`), so a
    /// plan whose source tab is zoomed unzooms it first. The move landing AND
    /// the tab coming back unzoomed are both the guard working.
    @MainActor
    func testAMoveOutOfAZoomedTabUnzoomsItAndStillLands() throws {
        let ids = session.seedIDs()
        try session.mutate(#"{"id":"e2e-zoom","method":"pane.zoom","params":{"pane_id":"\#(ids.p1)","mode":"on"}}"#)
        let zoomed = try session.snapshot(waitingFor: "\(ids.tabA) to read as zoomed") { $0.isZoomed(tab: ids.tabA) }
        XCTAssertEqual(
            zoomed.focusedPaneID, ids.p1,
            "the zoom badge is drawn on the tab's focused pane, so this case needs \(ids.p1) focused; \(zoomed.outline())"
        )

        // A zoomed tab draws the pane the zoom holds open and nothing else, so
        // the seed's other cell is not there to wait for.
        let app = try launchOnSeed(drawing: [ids.p1])
        XCTAssertTrue(
            app.paddockElement(zoomBadge(ids.p1)).waitForExistence(timeout: 20),
            "the window never marked \(ids.p1) zoomed, so the guard below would be tested against nothing"
        )

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "paddock.strip.tab.\(ids.tabB)", aiming: .middle)

        let after = try session.snapshot(waitingFor: "\(ids.p1) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p1) == ids.tabB
        }
        XCTAssertFalse(
            after.isZoomed(tab: ids.tabA),
            "the plan must unzoom the source tab before the move, and leave it unzoomed; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabB).sorted(), [ids.p1, ids.p3].sorted(),
            "the move out of the zoomed tab did not land; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA); \(after.outline())"
        )

        // The badge's absence is asserted OF a window that is drawing what it
        // should, in one capture, never on its own. The canvas holds nothing
        // at all for a moment while it tears one tab's layout down and builds
        // the other's, and no badge is drawn in that moment either, so a bare
        // "no badge" would pass whatever the unzoom did or did not do.
        let expected = Set([ids.p3, ids.p1].map { canvasPane($0) })
        assertEventually("\(ids.tabB)'s two panes are drawn with no zoom badge on either") {
            let drawn = app.paddockIdentifiers(prefix: "paddock.")
            return Set(drawn.filter { $0.hasPrefix(Self.canvasPanePrefix) }) == expected
                && !drawn.contains { $0.hasPrefix(Self.zoomBadgePrefix) }
        } describing: {
            let drawn = app.paddockIdentifiers(prefix: "paddock.")
            let cells = drawn.filter { $0.hasPrefix(Self.canvasPanePrefix) }
            let badges = drawn.filter { $0.hasPrefix(Self.zoomBadgePrefix) }
            return "the canvas holds [\(cells.joined(separator: ", "))], expected "
                + "[\(expected.sorted().joined(separator: ", "))], and the window draws the zoom badges "
                + "[\(badges.joined(separator: ", "))]"
        }
    }

    /// A pane released on a rail row lands in that workspace, in a tab of its
    /// own, re-keyed.
    ///
    /// Crossed slowly, so the drag dwells on the row on its way to the drop:
    /// `DragController` reads its spring-load deadline from the move events a
    /// drag delivers, and a pointer parked dead still never reaches one. The
    /// dwell's own reveal is not observable from here (see the note on the
    /// suite), so what this asserts is where the drop lands.
    @MainActor
    func testADragReleasedOnAWorkspaceRowLandsInThatWorkspace() throws {
        let ids = session.seedIDs()
        let (other, otherTab, otherPane) = try makeSecondWorkspace()
        let app = try launchOnSeed()
        XCTAssertTrue(
            app.paddockElement("paddock.rail.workspace.\(other)").waitForExistence(timeout: 20),
            "the rail never drew a row for \(other), so there was nothing to drop on"
        )

        let dropped = dragElement(
            app, fromID: canvasPane(ids.p1), toID: "paddock.rail.workspace.\(other)", aiming: .edge(.left),
            speed: Self.dwellCrossingSpeed
        )
        let after = try session.snapshot(waitingFor: "\(ids.p1) to land in a new tab of \(other). \(dropped)") {
            $0.tabCount(inWorkspace: other) == 2
        }
        let landedTab = try XCTUnwrap(
            after.tabIDs(inWorkspace: other).first { $0 != otherTab },
            "no tab beyond \(other)'s own exists; \(after.outline())"
        )
        let landed = try XCTUnwrap(
            after.paneIDs(inTab: landedTab).first, "\(landedTab) holds no pane; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: landedTab).count, 1,
            "the tab the drop made should hold the dropped pane and nothing else; \(after.outline())"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: otherTab), [otherPane],
            "the drop made a tab of its own rather than joining \(other)'s existing one; \(after.outline())"
        )
        XCTAssertNotEqual(
            landed, ids.p1,
            "a pane carried across workspaces is re-keyed, so it must not still answer to \(ids.p1)"
        )
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA); \(after.outline())"
        )
        assertCanvasHolds(app, [landed], "after the dwelled drag was released on \(other)")
    }

    // MARK: - Fixtures for the gestures above

    /// A thumbnail is 120 wide by 101 tall (`ChromeMetrics.Grid.thumbnailWidth`
    /// and `thumbnailHeight`), with a 15pt tab handle across its top
    /// (`tabStripHeight`) and 4pt of padding (`thumbnailPadding`) around the
    /// pane area below it. So the mini panes run from about y=19 to y=97 of
    /// the box, and 0.6 of its height sits inside them, clear of both the
    /// handle above and the edge bands the drop resolver reads.
    private static let miniPaneY: CGFloat = 0.6

    /// How far inside a thumbnail's left or right side a point still lands in
    /// the mini pane there AND inside that pane's own edge band: the band is a
    /// fifth of the pane (`edgeBandFraction`), the padding is 4pt of 120.
    private static let miniPaneEdgeX: CGFloat = 0.08

    /// The seed's `tabA` splits right, so its thumbnail draws two mini panes
    /// side by side: the first (`p1`) covers the left half, the second (`p2`)
    /// the right.
    private static let firstMiniPaneOfTwo = Aim.fraction(x: 0.25, y: miniPaneY)
    private static let secondMiniPaneOfTwo = Aim.fraction(x: 0.75, y: miniPaneY)

    /// The tab's own handle across the top of its thumbnail, which is the one
    /// part of it no mini pane covers.
    private static let thumbnailHandle = Aim.fraction(x: 0.5, y: 0.07)

    /// Points per second for a drag that has to dwell on what it crosses. The
    /// rail is about 192pt wide, so aiming at a row's far side spends over a
    /// second inside it, against `DragController`'s 500ms dwell.
    private static let dwellCrossingSpeed: XCUIGestureVelocity = 120

    /// The one spelling of each identifier family the suite reads, so a
    /// prefix filter and a full identifier can never drift apart.
    private static let canvasPanePrefix = "paddock.canvas.pane."
    private static let zoomBadgePrefix = "paddock.pane.zoomBadge."

    private func canvasPane(_ paneID: String) -> String { Self.canvasPanePrefix + paneID }

    private func gridTab(_ tabID: String) -> String { "paddock.grid.tab.\(tabID)" }

    private func zoomBadge(_ paneID: String) -> String { Self.zoomBadgePrefix + paneID }

    /// A second workspace for the rail row a pane is dropped on, made through
    /// herdr rather than through the app so the window has nothing to do with
    /// it existing. Returns its id, its one tab's, and that tab's one pane's.
    private func makeSecondWorkspace() throws -> (workspace: String, tab: String, pane: String) {
        let ids = session.seedIDs()
        try session.mutate(#"{"id":"e2e-ws","method":"workspace.create","params":{"cwd":"/tmp","label":"other"}}"#)
        // herdr focuses a workspace it just made, and the drags start from the
        // seed's own tab, so the window has to come up showing that one.
        try session.mutate(#"{"id":"e2e-back","method":"workspace.focus","params":{"workspace_id":"\#(ids.ws)"}}"#)
        let seeded = try session.snapshot(waitingFor: "a second workspace, with the seed's focused") {
            $0.workspaceCount == 2 && $0.focusedWorkspaceID == ids.ws
        }
        let other = try XCTUnwrap(
            seeded.orderedWorkspaceIDs().first { $0 != ids.ws }, "the second workspace was never made"
        )
        let tab = try XCTUnwrap(seeded.tabIDs(inWorkspace: other).first, "\(other) holds no tab; \(seeded.outline())")
        let pane = try XCTUnwrap(seeded.paneIDs(inTab: tab).first, "\(tab) holds no pane; \(seeded.outline())")
        return (other, tab, pane)
    }

    /// Launches the app on the reseeded session and waits until the canvas is
    /// drawing `panes`, which is the state the gesture starts from.
    ///
    /// `panes` defaults to both of the seed's shown tab, which is what a
    /// tiled tab draws. A zoomed tab draws only the pane the zoom holds open
    /// (`CanvasComposition`), so the case that zooms first names that one:
    /// waiting for a cell a zoomed canvas never draws would time out before
    /// the gesture ran.
    @MainActor
    private func launchOnSeed(drawing panes: [String]? = nil) throws -> XCUIApplication {
        let ids = session.seedIDs()
        let wanted = panes ?? [ids.p1, ids.p2]
        // Registered before the launch that needs it, and capturing nothing:
        // an assertion failure under `continueAfterFailure = false` unwinds
        // this method through Objective-C, where a `defer` is not reliable,
        // and an app left attached to a session the wrapper is about to stop
        // outlives the whole run.
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.paddock(socket: session.socketPath)
        for (index, pane) in wanted.enumerated() {
            XCTAssertTrue(
                app.paddockElement(canvasPane(pane)).waitForExistence(timeout: index == 0 ? 60 : 30),
                "the canvas never drew \(pane), so the drag below had nothing to grab"
            )
        }
        return app
    }

    @MainActor
    private func openGrid(_ app: XCUIApplication, ids: SeedIDs) {
        clickElement(app, "paddock.rail.allWorkspaces")
        // The list of everything on screen, not just the verdict: a thumbnail
        // that never appeared can mean the grid did not open (the rail and
        // strip would still be listed) or that the card it sits in swallowed
        // its identifier (the card would be listed and no thumbnail would be),
        // and those want different fixes.
        assertEventually("the All Workspaces grid draws a thumbnail for \(ids.tabA) and \(ids.tabB)") {
            app.paddockElement(self.gridTab(ids.tabA)).exists && app.paddockElement(self.gridTab(ids.tabB)).exists
        } describing: {
            "a cross-tab pane drop needs both tabs' panes on screen at once, which only the grid draws. "
                + "The window is showing [\(app.paddockIdentifiers(prefix: "paddock.").joined(separator: ", "))]"
        }
    }

    /// Selects a tab from its grid thumbnail, which also closes the grid, so
    /// the canvas can be read afterward.
    @MainActor
    private func showTabFromGrid(_ app: XCUIApplication, _ tabID: String) {
        // The thumbnail's handle strip, not its middle: the middle belongs to
        // a mini pane, which carries a drag gesture of its own.
        clickElement(app, gridTab(tabID), at: Self.thumbnailHandle)
        // The grid's absence read together with the canvas's return, in one
        // capture. On its own, "no thumbnail" is also true of the moment
        // between the grid tearing down and the canvas drawing anything.
        assertEventually("the grid closes and the canvas comes back") {
            let drawn = app.paddockIdentifiers(prefix: "paddock.")
            return !drawn.contains(self.gridTab(tabID))
                && drawn.contains { $0.hasPrefix(Self.canvasPanePrefix) }
        } describing: {
            "the window is showing [\(app.paddockIdentifiers(prefix: "paddock.").joined(separator: ", "))]"
        }
    }

    @MainActor
    private func assertCanvasHolds(
        _ app: XCUIApplication, _ paneIDs: [String], _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let wanted = Set(paneIDs.map { canvasPane($0) })
        assertEventually(what, file: file, line: line) {
            Set(app.paddockIdentifiers(prefix: Self.canvasPanePrefix)) == wanted
        } describing: {
            let seen = app.paddockIdentifiers(prefix: Self.canvasPanePrefix)
            return "the canvas holds [\(seen.joined(separator: ", "))], expected [\(wanted.sorted().joined(separator: ", "))]"
        }
    }

    /// Both cells read out of one capture, so the comparison is of two boxes
    /// the window held at the same instant, and a cell that has since moved
    /// reads as absent rather than failing the test from inside the helper.
    @MainActor
    private func assertCellIsLeftOf(
        _ app: XCUIApplication, _ leftPane: String, _ rightPane: String, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func boxes() -> (left: CGRect, right: CGRect)? {
            let drawn = app.paddockBoxes(prefix: Self.canvasPanePrefix)
            guard let left = drawn[canvasPane(leftPane)], let right = drawn[canvasPane(rightPane)] else { return nil }
            return (left, right)
        }
        assertEventually(what, file: file, line: line) {
            guard let pair = boxes() else { return false }
            return pair.left.maxX <= pair.right.minX + 1
        } describing: {
            guard let pair = boxes() else {
                return "the canvas is not drawing both \(leftPane) and \(rightPane)"
            }
            return "\(leftPane) is at \(pair.left), \(rightPane) at \(pair.right)"
        }
    }

}
