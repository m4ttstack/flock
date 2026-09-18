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
    ///
    /// Waited out by settling rather than by the pane's arrival, and that is
    /// the difference between this case reading the drop and reading its own
    /// timing: the arrival is the FIRST of the plan's two ops, true about a
    /// millisecond before the swap that composes the pair, so a snapshot taken
    /// on it holds the split without the swap every time rather than now and
    /// then. Settling names no side, so the assertions below can still fail.
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

        let after = try session.settledLayout(inTab: ids.tabB, holding: [ids.p1, ids.p3], "\(trace)")
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA) entirely; \(after.outline())"
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

    /// The same gesture, read off the wire instead of off the layout it left.
    ///
    /// Three targets put the moved pane beside `p3` in `tabB`, and only one of
    /// them composes: the tab's own handle names no pane and splits beside
    /// whichever one that tab has focused, the pane's interior splits right of
    /// it, and the left band splits right and then swaps. The layout afterwards
    /// is the same for the first two and for a composition whose swap never
    /// ran, so the case above cannot say which of them it got. This one reads
    /// what the app actually asked herdr for, through the fault proxy it is
    /// launched against.
    ///
    /// The outcomes it separates, each on its own assertion: no `pane.move` at
    /// all (the drop never committed), a move naming no target pane (the
    /// handle), a move with no `pane.swap` behind it (the interior, or a
    /// composition that stopped), a swap herdr answered with a reason (a
    /// composition it refused), a swap herdr took and did nothing about
    /// (`changed` false, which an acknowledgement alone would hide), a swap
    /// whose own reply puts the panes in the un-composed order (herdr's swap
    /// not meaning what the composition assumes for this shape), and a
    /// composition that herdr held and then lost (something after the two ops
    /// putting it back, which the recorded tail names).
    @MainActor
    func testTheLeftEdgeDropSendsBothOpsAndLeavesHerdrComposed() throws {
        let ids = session.seedIDs()
        let proxy = try session.startFaultProxy()
        let app = try launchOnSeed(socket: proxy)
        openGrid(app, ids: ids)

        let trace = dragElement(
            app,
            fromID: gridTab(ids.tabA), grabbing: Self.firstMiniPaneOfTwo,
            toID: gridTab(ids.tabB), aiming: .fraction(x: Self.miniPaneEdgeX, y: Self.miniPaneY)
        )
        _ = try session.snapshot(waitingFor: "\(ids.p1) to join \(ids.tabB). \(trace)") {
            $0.tabID(ofPane: ids.p1) == ids.tabB
        }

        // Waited for the swap's ANSWER, not for the swap. The wait above ends
        // the instant the move's own effect reaches herdr, which is a
        // millisecond before the swap is even sent, so a recording read on the
        // strength of the request alone reports "no answer" for a verb that is
        // still in flight and reads exactly like one herdr never took. This
        // wait is generous against the client's own 15s deadline: a swap still
        // unanswered here is one the app is genuinely parked on.
        let sent = try waitForRecording { exchanges in
            exchanges.contains { $0.method == "pane.swap" && $0.answer != .none }
        }

        // Everything is gathered before anything is asserted, and every
        // reading is printed. The suite stops at its first failure, so an
        // assertion placed before a reading is a reading the run never takes,
        // and each of these is the evidence for a different answer.
        let composed = try settledSnapshot { snapshot in
            guard let moved = snapshot.paneRect(ids.p1), let anchor = snapshot.paneRect(ids.p3) else { return false }
            return moved.x < anchor.x
        }
        Thread.sleep(forTimeInterval: Self.settleWindowSeconds)
        let afterwards = try session.snapshot()
        let tail = try session.faultProxyRecording()
        print("PROXY what the drop sent:\(sent.outline())")
        print("PROXY everything the app asked for, the tail included:\(tail.outline())")
        print("PROXY herdr held [\(Self.sides(composed, ids))] once it settled, "
            + "and [\(Self.sides(afterwards, ids))] \(Self.settleWindowSeconds)s later")

        let moves = sent.filter { $0.method == "pane.move" }
        XCTAssertEqual(
            moves.count, 1,
            "one left-edge drop is one pane.move; the app sent \(moves.count). \(sent.outline())"
        )
        guard let move = moves.first else { return }
        XCTAssertEqual(
            move.param("destination", "tab_id") as? String, ids.tabB,
            "the move did not name \(ids.tabB). \(sent.outline())"
        )
        XCTAssertEqual(
            move.param("destination", "target_pane_id") as? String, ids.p3,
            "the move named no target pane, which is the drop the tab's own handle sends: the pointer "
                + "resolved to \(ids.tabB) rather than to \(ids.p3)'s left band. \(sent.outline())"
        )
        XCTAssertEqual(move.answer, .ok, "herdr did not take the move. \(sent.outline())")
        XCTAssertEqual(
            move.changed, true,
            "herdr acknowledged the move without moving anything. \(sent.outline())"
        )

        let swaps = sent.filter { $0.method == "pane.swap" }
        XCTAssertEqual(
            swaps.count, 1,
            "a left-edge drop splits right and then swaps; the app sent \(swaps.count) pane.swap. \(sent.outline())"
        )
        guard let swap = swaps.first else { return }
        XCTAssertGreaterThan(
            swap.requestAtMilliseconds, move.requestAtMilliseconds,
            "the swap must follow the move it compensates for. \(sent.outline())"
        )
        XCTAssertEqual(
            swap.param("source_pane_id") as? String, ids.p1,
            "the swap named the wrong pane to move. \(sent.outline())"
        )
        XCTAssertEqual(
            swap.param("target_pane_id") as? String, ids.p3,
            "the swap named the wrong pane to trade with. \(sent.outline())"
        )
        // How long herdr itself held the un-composed order: a composition is
        // two ops, so anything reading the session in between sees the split
        // without the swap. This is the width of that window, measured rather
        // than assumed, and it is what says whether a reader can land in it.
        if let moveAnswered = move.replyAtMilliseconds, let swapAnswered = swap.replyAtMilliseconds {
            print(String(
                format: "PROXY herdr held the un-composed order for %.1fms (move answered at %.1fms, swap at %.1fms)",
                swapAnswered - moveAnswered, moveAnswered, swapAnswered
            ))
        }
        XCTAssertEqual(
            swap.answer, .ok,
            "herdr did not take the swap, with \(Self.recordingWaitSeconds)s allowed for the answer and the "
                + "app's own deadline at 15s. \(sent.outline())"
        )
        // An acknowledgement is not an effect. herdr answers a verb it
        // declined with a success carrying a reason, but a verb it took and
        // had nothing to do about answers with neither, and a composition
        // whose second op is a no-op leaves exactly the layout this whole
        // investigation is about.
        XCTAssertEqual(
            swap.changed, true,
            "herdr took the swap and changed nothing. \(sent.outline())"
        )

        // herdr's own word for what the swap did, out of the swap's reply
        // rather than out of a snapshot: the reply is the tab as that verb
        // left it, so a composed reply followed by an un-composed session
        // means something after the swap put it back, and an un-composed
        // reply means the swap never composed it in the first place.
        let swapped = try XCTUnwrap(
            swap.replyPaneRects(),
            "the swap's reply carried no layout to read. \(sent.outline())"
        )
        let movedInReply = try XCTUnwrap(swapped[ids.p1], "the swap's reply holds no rect for \(ids.p1)")
        let anchorInReply = try XCTUnwrap(swapped[ids.p3], "the swap's reply holds no rect for \(ids.p3)")
        XCTAssertLessThan(
            movedInReply.x, anchorInReply.x,
            "herdr's own reply to the swap puts \(ids.p1) at x=\(movedInReply.x) and \(ids.p3) at "
                + "x=\(anchorInReply.x), so the swap did not compose this shape. \(sent.outline())"
        )

        // And what the session holds, read from herdr directly rather than
        // through the app, once it has had a moment to settle.
        let moved = try XCTUnwrap(composed.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let anchor = try XCTUnwrap(composed.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertLessThan(
            moved.x, anchor.x,
            "herdr's reply composed the pair and the session did not: \(ids.p1) is at x=\(moved.x) and "
                + "\(ids.p3) at x=\(anchor.x). \(composed.outline()) \(sent.outline())"
        )

        // The settle window read last, though it was taken first: a correction
        // arriving after the plan finishes is the other way this ends
        // un-composed, and the tail beside it names whatever sent one.
        let held = try XCTUnwrap(afterwards.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let heldAnchor = try XCTUnwrap(afterwards.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertLessThan(
            held.x, heldAnchor.x,
            "the composition landed and was then undone: \(ids.p1) is at x=\(held.x) and \(ids.p3) at "
                + "x=\(heldAnchor.x) \(Self.settleWindowSeconds)s later. Everything the app asked for, the "
                + "tail included: \(tail.outline()) \(afterwards.outline())"
        )
    }

    /// How long the case above keeps watching after the plan finishes. Wide
    /// enough to cover the store's own convergence timeout and a resnapshot
    /// interval, which are what a late correction would ride in on.
    private static let settleWindowSeconds: TimeInterval = 3

    /// The composition on the other axis: the top band is the second of the
    /// two bands `pane.move` cannot place directly, so this is the same split
    /// and swap turned ninety degrees, and the moved pane ending ABOVE is the
    /// point.
    ///
    /// Both neighbours of this aim produce a side by side pair rather than a
    /// stacked one: the handle strip above the band splits right of the tab's
    /// focused pane, and the interior below it splits right of the pane itself.
    /// So an aim that slips either way fails here rather than passing on a
    /// different verb's result.
    @MainActor
    func testTopEdgeDropComposesTheMovedPaneAboveItsTarget() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()
        openGrid(app, ids: ids)

        let trace = dragElement(
            app,
            fromID: gridTab(ids.tabA), grabbing: Self.firstMiniPaneOfTwo,
            toID: gridTab(ids.tabB), aiming: .fraction(x: 0.5, y: Self.miniPaneEdgeY)
        )

        let after = try session.settledLayout(inTab: ids.tabB, holding: [ids.p1, ids.p3], "\(trace)")
        XCTAssertEqual(
            after.paneIDs(inTab: ids.tabA), [ids.p2],
            "the pane should have left \(ids.tabA) entirely; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p3), "\(ids.p3) has no rect in any layout")
        XCTAssertLessThan(
            moved.y, anchor.y,
            "a top-edge drop splits down and then swaps, so the moved pane ends ABOVE; got \(ids.p1) at "
                + "y=\(moved.y) and \(ids.p3) at y=\(anchor.y), which is the un-composed order"
        )
        XCTAssertEqual(moved.x, anchor.x, "a down split leaves both panes on the same x, got \(moved.x) and \(anchor.x)")

        showTabFromGrid(app, ids.tabB)
        assertCanvasHolds(app, [ids.p1, ids.p3], "after a top-edge drop into \(ids.tabB)")
        assertCellIsAbove(app, ids.p1, ids.p3, "the canvas did not draw the composed order")
    }

    /// The same-tab composition: herdr refuses a same-tab `pane.move`, so a
    /// left-edge drop inside one tab parks the pane in a tab of its own,
    /// splits it back in beside its target, closes the tab it made, and then
    /// swaps the pair. Four ops, and the last one is the whole difference
    /// between this and doing nothing.
    ///
    /// Started from a split deliberately off the middle, because the order
    /// alone cannot tell this apart from the plain interior swap the case
    /// below drives: both end with the dragged pane on the left. The widths
    /// can. An interior swap trades the panes and leaves the ratio where it
    /// was (84 and 36 cells here); the bounce rebuilds the split at a half, so
    /// the pair comes back even. Measured against a live herdr, not assumed.
    ///
    /// Aimed by `Aim.edge`, a twentieth of the target cell in from its side,
    /// which is a quarter of the way into the fifth of the cell the band
    /// covers: a twentieth of the cell to the outside of it and three
    /// twentieths to the interior.
    @MainActor
    func testSameTabLeftEdgeBounceRebuildsTheSplitEvenly() throws {
        let ids = session.seedIDs()
        // Before the launch: the window then comes up on the shape the drag
        // starts from rather than relaying out underneath it.
        try session.mutate(
            #"{"id":"e2e-ratio","method":"layout.set_split_ratio","params":{"tab_id":"\#(ids.tabA)","path":[],"ratio":0.7}}"#
        )
        let widened = try session.snapshot(waitingFor: "\(ids.tabA)'s split to move off the middle") {
            guard let left = $0.paneRect(ids.p1), let right = $0.paneRect(ids.p2) else { return false }
            return left.width != right.width
        }
        let uneven = try XCTUnwrap(widened.paneRect(ids.p1), "\(ids.p1) has no rect in the widened seed")
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p2), toID: canvasPane(ids.p1), aiming: .edge(.left))

        let after = try session.settledLayout(inTab: ids.tabA, holding: [ids.p1, ids.p2], "\(trace)")
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "the tab the bounce parked the pane in was not closed; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        XCTAssertLessThan(
            moved.x, anchor.x,
            "a left-edge drop splits right and then swaps, so the moved pane ends on the LEFT; got \(ids.p2) "
                + "at x=\(moved.x) and \(ids.p1) at x=\(anchor.x)"
        )
        XCTAssertEqual(
            moved.width, anchor.width,
            "the bounce splits back in at a half, so the pair must come back even; got \(ids.p2) at "
                + "\(moved.width) cells and \(ids.p1) at \(anchor.width). A pair still \(uneven.width) and "
                + "\(after.paneRect(ids.p1)?.width ?? -1) apart is the plain swap the interior sends, which "
                + "means this drop landed in the pane's middle rather than its left band"
        )

        assertCanvasHolds(app, [ids.p1, ids.p2], "after a same-tab left-edge bounce")
        assertCellIsLeftOf(app, ids.p2, ids.p1, "the canvas did not draw the composed order")
    }

    /// The same bounce on the other axis: four ops again, ending with the
    /// swap that puts the moved pane on TOP.
    ///
    /// This one needs no ratio to be honest: the drop the interior sends
    /// leaves the pair side by side, and the one the bottom band sends puts
    /// the moved pane underneath, so neither can produce what this asserts.
    /// A missing trailing swap leaves the target on top, which is the same
    /// arrangement the bottom-edge case ends in and the opposite of this one.
    @MainActor
    func testSameTabTopEdgeBounceStacksTheMovedPaneOnTop() throws {
        let ids = session.seedIDs()
        let app = try launchOnSeed()

        let trace = dragElement(app, fromID: canvasPane(ids.p2), toID: canvasPane(ids.p1), aiming: .edge(.top))

        let after = try session.settledLayout(inTab: ids.tabA, holding: [ids.p1, ids.p2], "\(trace)")
        XCTAssertEqual(
            after.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB],
            "the tab the bounce parked the pane in was not closed; \(after.outline())"
        )
        XCTAssertEqual(
            after.splitDirections(inTab: ids.tabA), ["down"],
            "a top-edge drop restructures the tab into a down split; \(after.outline())"
        )
        let moved = try XCTUnwrap(after.paneRect(ids.p2), "\(ids.p2) has no rect in any layout")
        let anchor = try XCTUnwrap(after.paneRect(ids.p1), "\(ids.p1) has no rect in any layout")
        XCTAssertLessThan(
            moved.y, anchor.y,
            "a top-edge drop splits down and then swaps, so the moved pane ends ABOVE; got \(ids.p2) at "
                + "y=\(moved.y) and \(ids.p1) at y=\(anchor.y), which is what a missing swap leaves"
        )
        XCTAssertEqual(moved.x, anchor.x, "a down split leaves both panes on the same x, got \(moved.x) and \(anchor.x)")

        assertCanvasHolds(app, [ids.p1, ids.p2], "after a same-tab top-edge bounce")
        assertCellIsAbove(app, ids.p2, ids.p1, "the canvas did not draw the composed order")
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
            let drawn = app.flockBoxes(prefix: Self.canvasPanePrefix)
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

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "flock.strip.newTab", aiming: .edge(.right))

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
            app.flockElementCount(identifierPrefix: "flock.strip.tab.") == 3
        } describing: {
            "the strip holds \(app.flockIdentifiers(prefix: "flock.strip.tab.").joined(separator: ", "))"
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

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "flock.rail.newWorkspace", aiming: .edge(.bottom))

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
            app.flockElementCount(identifierPrefix: "flock.rail.workspace.") == 2
        } describing: {
            "the rail holds \(app.flockIdentifiers(prefix: "flock.rail.workspace.").joined(separator: ", "))"
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

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "flock.strip.tab.\(ids.tabB)", aiming: .middle)

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
            app.flockElement(zoomBadge(ids.p1)).waitForExistence(timeout: 20),
            "the window never marked \(ids.p1) zoomed, so the guard below would be tested against nothing"
        )

        let trace = dragElement(app, fromID: canvasPane(ids.p1), toID: "flock.strip.tab.\(ids.tabB)", aiming: .middle)

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
            let drawn = app.flockIdentifiers(prefix: "flock.")
            return Set(drawn.filter { $0.hasPrefix(Self.canvasPanePrefix) }) == expected
                && !drawn.contains { $0.hasPrefix(Self.zoomBadgePrefix) }
        } describing: {
            let drawn = app.flockIdentifiers(prefix: "flock.")
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
            app.flockElement("flock.rail.workspace.\(other)").waitForExistence(timeout: 20),
            "the rail never drew a row for \(other), so there was nothing to drop on"
        )

        let dropped = dragElement(
            app, fromID: canvasPane(ids.p1), toID: "flock.rail.workspace.\(other)", aiming: .edge(.left),
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

    /// How far below a thumbnail's top a point lands in the mini pane's own
    /// TOP band. Swept offscreen against the real grid at hundredths of the
    /// thumbnail: the band runs from 19pt to 34.6pt of the 101pt thumbnail,
    /// with the tab's handle strip and the padding under it above that and the
    /// pane's interior below. This aims at 26.3pt, 7.3pt clear of the handle
    /// and 8.3pt clear of the interior, and both of those neighbours split
    /// right rather than down, so a slip either way fails a stacked assertion
    /// rather than passing one.
    private static let miniPaneEdgeY: CGFloat = 0.26

    /// How far inside a thumbnail's left or right side a point still lands in
    /// the mini pane there AND inside that pane's own edge band. On the 120pt
    /// thumbnail that band runs from 4pt to 26.4pt: below it is
    /// `thumbnailPadding`, which is the tab's own handle and splits beside the
    /// tab's focused pane rather than composing anything, and above it is the
    /// pane's interior. Aimed at the middle of that range rather than at
    /// either end: both neighbours still land the pane in the right tab beside
    /// the right pane, so a point that slips into one reads here as the
    /// composition itself having failed.
    private static let miniPaneEdgeX: CGFloat = 0.12

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
    private static let canvasPanePrefix = "flock.canvas.pane."
    private static let zoomBadgePrefix = "flock.pane.zoomBadge."

    private func canvasPane(_ paneID: String) -> String { Self.canvasPanePrefix + paneID }

    private func gridTab(_ tabID: String) -> String { "flock.grid.tab.\(tabID)" }

    private func zoomBadge(_ paneID: String) -> String { Self.zoomBadgePrefix + paneID }

    /// Polls herdr until `condition` holds and hands back that snapshot, or
    /// hands back the last one it read when the wait runs out.
    ///
    /// Unlike `ScratchSession.snapshot(waitingFor:)` this never throws on the
    /// timeout: the case using it asserts on what herdr was actually holding,
    /// with the app's own recording beside it, and a throw here would report
    /// the wait in place of the finding.
    private func settledSnapshot(
        timeout: TimeInterval = 10, until condition: (HerdrSnapshotJSON) -> Bool
    ) throws -> HerdrSnapshotJSON {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try session.snapshot()
        while Date() < deadline, !condition(latest) {
            usleep(200_000)
            latest = try session.snapshot()
        }
        return latest
    }

    /// The proxy's recording once `predicate` holds, or once the wait runs
    /// out. It never fails on its own: what the wait did not find is the
    /// finding, and the assertions that read it are where that is said.
    private func waitForRecording(
        timeout: TimeInterval = PaneDragTests.recordingWaitSeconds, until predicate: ([ProxyExchange]) -> Bool
    ) throws -> [ProxyExchange] {
        let deadline = Date().addingTimeInterval(timeout)
        var sent = try session.faultProxyRecording()
        while Date() < deadline, !predicate(sent) {
            usleep(200_000)
            sent = try session.faultProxyRecording()
        }
        return sent
    }

    /// How long a verb is given to be answered before the recording is read as
    /// final. Under the client's own 15s deadline, so a verb still unanswered
    /// here is one the app is still parked on rather than one it has given up
    /// on, and far enough over herdr's sub-millisecond answers that the gap is
    /// a finding rather than a schedule.
    private static let recordingWaitSeconds: TimeInterval = 10

    /// Which side of `tabB` each pane is on, for a line of output that reads
    /// at a glance.
    private static func sides(_ snapshot: HerdrSnapshotJSON, _ ids: SeedIDs) -> String {
        [ids.p1, ids.p3]
            .map { pane in snapshot.paneRect(pane).map { "\(pane)@x=\($0.x)" } ?? "\(pane) nowhere" }
            .joined(separator: " ")
    }

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
    ///
    /// `socket` is the session's own unless a case hands over the fault
    /// proxy's, which relays to it and records what the app asks for.
    @MainActor
    private func launchOnSeed(drawing panes: [String]? = nil, socket: String? = nil) throws -> XCUIApplication {
        let ids = session.seedIDs()
        let wanted = panes ?? [ids.p1, ids.p2]
        // Registered before the launch that needs it, and capturing nothing:
        // an assertion failure under `continueAfterFailure = false` unwinds
        // this method through Objective-C, where a `defer` is not reliable,
        // and an app left attached to a session the wrapper is about to stop
        // outlives the whole run.
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.flock(socket: socket ?? session.socketPath)
        for (index, pane) in wanted.enumerated() {
            XCTAssertTrue(
                app.flockElement(canvasPane(pane)).waitForExistence(timeout: index == 0 ? 60 : 30),
                "the canvas never drew \(pane), so the drag below had nothing to grab"
            )
        }
        return app
    }

    @MainActor
    private func openGrid(_ app: XCUIApplication, ids: SeedIDs) {
        clickElement(app, "flock.rail.allWorkspaces")
        // The list of everything on screen, not just the verdict: a thumbnail
        // that never appeared can mean the grid did not open (the rail and
        // strip would still be listed) or that the card it sits in swallowed
        // its identifier (the card would be listed and no thumbnail would be),
        // and those want different fixes.
        assertEventually("the All Workspaces grid draws a thumbnail for \(ids.tabA) and \(ids.tabB)") {
            app.flockElement(self.gridTab(ids.tabA)).exists && app.flockElement(self.gridTab(ids.tabB)).exists
        } describing: {
            "a cross-tab pane drop needs both tabs' panes on screen at once, which only the grid draws. "
                + "The window is showing [\(app.flockIdentifiers(prefix: "flock.").joined(separator: ", "))]"
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
            let drawn = app.flockIdentifiers(prefix: "flock.")
            return !drawn.contains(self.gridTab(tabID))
                && drawn.contains { $0.hasPrefix(Self.canvasPanePrefix) }
        } describing: {
            "the window is showing [\(app.flockIdentifiers(prefix: "flock.").joined(separator: ", "))]"
        }
    }

    @MainActor
    private func assertCanvasHolds(
        _ app: XCUIApplication, _ paneIDs: [String], _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let wanted = Set(paneIDs.map { canvasPane($0) })
        assertEventually(what, file: file, line: line) {
            Set(app.flockIdentifiers(prefix: Self.canvasPanePrefix)) == wanted
        } describing: {
            let seen = app.flockIdentifiers(prefix: Self.canvasPanePrefix)
            return "the canvas holds [\(seen.joined(separator: ", "))], expected [\(wanted.sorted().joined(separator: ", "))]"
        }
    }

    /// The same comparison down the other axis, for the two drops that stack
    /// a pair rather than setting it side by side.
    @MainActor
    private func assertCellIsAbove(
        _ app: XCUIApplication, _ topPane: String, _ bottomPane: String, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func boxes() -> (top: CGRect, bottom: CGRect)? {
            let drawn = app.flockBoxes(prefix: Self.canvasPanePrefix)
            guard let top = drawn[canvasPane(topPane)], let bottom = drawn[canvasPane(bottomPane)] else { return nil }
            return (top, bottom)
        }
        assertEventually(what, file: file, line: line) {
            guard let pair = boxes() else { return false }
            return pair.top.maxY <= pair.bottom.minY + 1
        } describing: {
            guard let pair = boxes() else {
                return "the canvas is not drawing both \(topPane) and \(bottomPane)"
            }
            return "\(topPane) is at \(pair.top), \(bottomPane) at \(pair.bottom)"
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
            let drawn = app.flockBoxes(prefix: Self.canvasPanePrefix)
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
