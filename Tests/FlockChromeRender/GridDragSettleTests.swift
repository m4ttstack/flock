import FlockCore
import XCTest

/// Where the ghost goes when a grid drop commits nothing. The decision itself
/// is `DragVisuals.settleHomeTopLeft`; this drives the coordinator that feeds
/// it, which is the half `FlockCoreTests` cannot reach.
@MainActor
final class GridDragSettleTests: XCTestCase {
    private static let workspace = WorkspaceID(rawValue: "w1")
    private static let tab = TabID(rawValue: "w1:t1")
    private static let pane = PaneID(rawValue: "w1:p1")
    private static let card = CGRect(x: 10, y: 10, width: 500, height: 200)
    private static let thumbnail = CGRect(x: 20, y: 60, width: 100, height: 82)
    private static let neighbour = PaneID(rawValue: "w1:p2")
    /// One mini pane inside the thumbnail, stated in the thumbnail's space.
    private static let miniPaneBox = CGRect(x: 4, y: 4, width: 45, height: 74)
    /// Its neighbour, the other half of the same thumbnail.
    private static let neighbourBox = CGRect(x: 53, y: 4, width: 43, height: 74)
    private static var neighbourOnScreen: CGRect {
        neighbourBox.offsetBy(dx: thumbnail.minX, dy: thumbnail.minY)
    }
    private static var miniPane: CGRect {
        CGRect(
            x: thumbnail.minX + miniPaneBox.minX, y: thumbnail.minY + miniPaneBox.minY,
            width: miniPaneBox.width, height: miniPaneBox.height
        )
    }

    private static func home(box: CGRect, item: GridItemID) -> DragCoordinator.DragHome {
        let frame = item == .tab(tab) ? thumbnail : card
        return DragCoordinator.DragHome(
            atStart: CGRect(
                x: frame.minX + box.minX, y: frame.minY + box.minY, width: box.width, height: box.height
            ),
            item: item, boxInItem: box
        )
    }

    /// What the commit seam was actually handed, for the cases that assert on
    /// the drop rather than on where the ghost went.
    @MainActor
    private final class CommitRecorder {
        var last: (subject: DragSubject, target: DropTarget)?
    }

    /// A shown grid with one card and one thumbnail, assembled from frame
    /// reports rather than from a window.
    private func makeCoordinator(outcome: DragOutcome = .noOp, recorder: CommitRecorder? = nil) -> DragCoordinator {
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { subject, target in
                recorder?.last = (subject, target)
                return outcome
            },
            reveal: { _ in }
        )
        drag.stripWorkspace = Self.workspace
        drag.toggleGrid()
        drag.gridViewport = CGRect(x: 0, y: 0, width: 600, height: 400)
        drag.setGridOrder([.card(Self.workspace), .tab(Self.tab)])
        drag.setGridItemFrame(Self.card, for: .card(Self.workspace))
        drag.setGridItemFrame(Self.thumbnail, for: .tab(Self.tab))
        // Two mini panes, so a point inside the thumbnail names one of them
        // the way a real thumbnail's does.
        drag.setGridMiniPanes(
            [
                MiniPaneLayout.Placed(pane: Self.pane, frame: Self.miniPaneBox),
                MiniPaneLayout.Placed(pane: Self.neighbour, frame: Self.neighbourBox),
            ],
            for: Self.tab
        )
        return drag
    }

    /// The same grid with the card previewing the tab a drop will create. The
    /// slot is the same size as the thumbnail, so a proxy of that size settles
    /// with its top-left exactly on the slot's origin.
    private static let newTabSlot = CGRect(x: 140, y: 60, width: 100, height: 82)

    private func makeCoordinatorPreviewingANewTab(outcome: DragOutcome) -> DragCoordinator {
        let drag = makeCoordinator(outcome: outcome)
        drag.setGridOrder([.card(Self.workspace), .tab(Self.tab), .newTab(Self.workspace)])
        drag.setGridItemFrame(Self.newTabSlot, for: .newTab(Self.workspace))
        return drag
    }

    /// A second tab beside the first, one `tabGap` along, so the card has two
    /// cells for a reorder to move between.
    private static let secondTab = TabID(rawValue: "w1:t2")
    private static let secondThumbnail = CGRect(x: 130, y: 60, width: 100, height: 82)

    private func makeCoordinatorWithTwoTabs(outcome: DragOutcome, recorder: CommitRecorder? = nil) -> DragCoordinator {
        let drag = makeCoordinator(outcome: outcome, recorder: recorder)
        drag.setGridOrder([.card(Self.workspace), .tab(Self.tab), .tab(Self.secondTab)])
        drag.setGridItemFrame(Self.thumbnail, for: .tab(Self.tab))
        drag.setGridItemFrame(Self.secondThumbnail, for: .tab(Self.secondTab))
        return drag
    }

    /// The second tab's own lone mini pane, laid out the way a real thumbnail
    /// lays one out: `thumbnailPadding` inside the thumbnail, below the handle
    /// strip. The padding either side of it is the tab's own handle, so the
    /// pane's edge band starts a few points in from the thumbnail's edge --
    /// which is what makes a point that stops short of the release land on a
    /// different verb.
    private static let secondTabPane = PaneID(rawValue: "w1:p3")
    private static let secondTabPaneBox = CGRect(
        x: ChromeMetrics.Grid.thumbnailPadding,
        y: ChromeMetrics.Grid.tabStripHeight + ChromeMetrics.Grid.thumbnailPadding,
        width: secondThumbnail.width - ChromeMetrics.Grid.thumbnailPadding * 2,
        height: secondThumbnail.height - ChromeMetrics.Grid.tabStripHeight - ChromeMetrics.Grid.thumbnailPadding * 2
    )

    private static func tabGhost(asMiniature: Bool = false) -> DragCoordinator.Ghost {
        DragCoordinator.Ghost(
            title: "agents", symbol: "rectangle.stack", originSize: thumbnail.size, isCompact: true,
            tabMiniature: asMiniature
                ? DragCoordinator.Ghost.TabMiniature(title: "agents", status: .idle, isFocusedTab: false, panes: [])
                : nil
        )
    }

    private var paneHome: DragCoordinator.DragHome {
        Self.home(box: Self.miniPaneBox, item: .tab(Self.tab))
    }

    private func paneGhost(originSize: CGSize) -> DragCoordinator.Ghost {
        DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: originSize, isCompact: true)
    }

    /// The commit runs in a task off the release, so the settle lands a turn
    /// or two later.
    private func awaitSettle(_ drag: DragCoordinator) async {
        for _ in 0..<100 where !drag.isSettling {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// A tab dragged by its handle strip carries the grab cursor the whole
    /// way, which a tab drag outside the grid never does. What the push is
    /// keyed on has to be what the pop is keyed on, or a release leaves the
    /// closed hand on screen for the rest of the session.
    func testAGridDragHoldsTheGrabCursorFromBeginToRelease() async {
        let drag = makeCoordinator()
        XCTAssertFalse(drag.holdsGrabCursor)

        drag.beginIfIdle(
            .tab(Self.tab), ghost: Self.tabGhost(), at: CGPoint(x: 40, y: 80),
            home: Self.home(box: CGRect(origin: .zero, size: Self.thumbnail.size), item: .tab(Self.tab))
        )
        XCTAssertTrue(drag.holdsGrabCursor)
        XCTAssertFalse(drag.isPaneDragInFlight, "a tab is not a pane, whatever cursor it carries")

        drag.release()
        await awaitSettle(drag)
        XCTAssertFalse(drag.holdsGrabCursor)
    }

    /// The same tab dragged from the strip, with no grid covering the window,
    /// keeps whatever cursor it had: the open hand belongs to the grid's own
    /// handles and to rearrange mode, not to every drag.
    func testATabDraggedWithNoGridShownHoldsNoGrabCursor() {
        let drag = makeCoordinator()
        drag.closeGrid()

        drag.beginIfIdle(.tab(Self.tab), ghost: Self.tabGhost(), at: CGPoint(x: 40, y: 80))
        XCTAssertFalse(drag.holdsGrabCursor)
    }

    /// A tab drag begun before its thumbnail has reported a frame has no
    /// footprint to be drawn at. Exact bounds would resolve that to nothing at
    /// all, so it falls back to the ordinary bounds, whose floor is what keeps
    /// the proxy on screen.
    func testATabProxyWithNoReportedFrameStillHasASize() {
        let miniature = DragCoordinator.Ghost.TabMiniature(title: "agents", status: .idle, isFocusedTab: false, panes: [])
        let sized = DragCoordinator.Ghost(
            title: "agents", symbol: "rectangle.stack", originSize: Self.thumbnail.size, isCompact: true,
            tabMiniature: miniature
        )
        XCTAssertEqual(DragVisuals.ghostSize(forOrigin: sized.originSize, bounds: sized.bounds), Self.thumbnail.size)

        let unsized = DragCoordinator.Ghost(
            title: "agents", symbol: "rectangle.stack", originSize: .zero, isCompact: true, tabMiniature: miniature
        )
        let size = DragVisuals.ghostSize(forOrigin: unsized.originSize, bounds: unsized.bounds)
        XCTAssertEqual(size, DragVisuals.compactGhostBounds.minimum)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// A pane drag still carries it wherever it starts, grid or canvas.
    func testAPaneDragHoldsTheGrabCursorWithOrWithoutTheGrid() {
        let drag = makeCoordinator()
        drag.closeGrid()

        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size), at: CGPoint(x: 30, y: 70)
        )
        XCTAssertTrue(drag.holdsGrabCursor)
        XCTAssertTrue(drag.isPaneDragInFlight)
    }

    /// A drop on a card's empty space really does make a tab, and that tab
    /// lands in the slot the placeholder was standing in. The ghost has to go
    /// there: settling on the whole card sends it to the card's own centre,
    /// which is nowhere the drop landed, and reads as a bounce home.
    func testACommittedNewTabDropSettlesOnThePlaceholdersSlot() async {
        let drag = makeCoordinatorPreviewingANewTab(outcome: .committed)
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.newTabSlot.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        // Inside the card, clear of its thumbnail and of the slot itself: the
        // card's own empty space, which is what resolves to the workspace.
        drag.move(to: CGPoint(x: 400, y: 180))
        XCTAssertEqual(drag.target, .workspaceThumbnail(Self.workspace))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.newTabSlot.origin)
    }

    /// A resting card over its cap draws no placeholder and lights its tile
    /// instead, so the tile is the cell the created tab lands in and the
    /// ghost has to settle there rather than on the card's centre.
    func testACommittedDropOnACardPreviewingOnItsTileSettlesOnTheTile() async {
        let drag = makeCoordinator(outcome: .committed)
        drag.setGridOrder([.card(Self.workspace), .tab(Self.tab), .tile(Self.workspace), .newTab(Self.workspace)])
        drag.setGridItemFrame(Self.newTabSlot, for: .tile(Self.workspace))
        drag.setGridItemFrame(Self.newTabSlot, for: .newTab(Self.workspace))

        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.newTabSlot.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        drag.move(to: CGPoint(x: 400, y: 180))
        XCTAssertEqual(drag.target, .workspaceThumbnail(Self.workspace))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.newTabSlot.origin)
    }

    /// A release inside the placeholder itself is a release on the card
    /// behind it, so it commits and settles exactly the same way.
    func testAReleaseInsideThePlaceholderLandsInItsOwnSlot() async {
        let drag = makeCoordinatorPreviewingANewTab(outcome: .committed)
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.newTabSlot.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        drag.move(to: CGPoint(x: Self.newTabSlot.midX, y: Self.newTabSlot.midY))
        XCTAssertEqual(drag.target, .workspaceThumbnail(Self.workspace), "the placeholder is not a target of its own")

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.newTabSlot.origin)
    }

    /// The slot is where a COMMITTED drop lands, and nothing else: a plan that
    /// commits nothing still springs the ghost home.
    func testANoOpOnACardPreviewingANewTabStillSpringsHome() async {
        let drag = makeCoordinatorPreviewingANewTab(outcome: .noOp)
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        drag.move(to: CGPoint(x: Self.newTabSlot.midX, y: Self.newTabSlot.midY))
        XCTAssertEqual(drag.target, .workspaceThumbnail(Self.workspace))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.miniPane.origin, "home, not the slot")
    }

    /// Released over the thumbnail it started in: the planner answers `.noOp`,
    /// so the ghost has to spring back onto the mini pane rather than vanish
    /// where it was let go.
    func testAPaneDroppedOnItsOwnTabsThumbnailSpringsBackOntoItsMiniPane() async {
        let drag = makeCoordinator()
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        // The tab's own handle strip, above every mini pane.
        drag.move(to: CGPoint(x: 90, y: Self.thumbnail.minY + 1))
        XCTAssertEqual(drag.target, .tabThumbnail(Self.tab))

        drag.release()
        await awaitSettle(drag)
        XCTAssertTrue(drag.isSettling)
        XCTAssertEqual(drag.ghostTopLeft, Self.miniPane.origin)
    }

    /// Brought back onto its own tab's thumbnail: a band there is withdrawn
    /// and reads as the tab itself, its own mini pane's middle names that pane
    /// and the planner refuses it, and either way the proxy goes straight back
    /// to the box it was picked up from rather than into the half of itself
    /// the band would have split.
    func testAPaneDroppedOnItsOwnMiniPaneSpringsStraightHome() async {
        let expected: [(CGPoint, DropTarget)] = [
            (CGPoint(x: Self.miniPane.minX + 1, y: Self.miniPane.midY), .tabThumbnail(Self.tab)),
            (CGPoint(x: Self.miniPane.midX, y: Self.miniPane.midY), .paneInterior(Self.pane)),
            (CGPoint(x: Self.neighbourOnScreen.minX + 1, y: Self.neighbourOnScreen.midY), .tabThumbnail(Self.tab)),
        ]
        for (point, target) in expected {
            let drag = makeCoordinator()
            drag.beginIfIdle(
                .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size),
                at: CGPoint(x: Self.miniPane.midX, y: Self.miniPane.midY), home: paneHome
            )
            drag.move(to: CGPoint(x: 300, y: 150))
            drag.move(to: point)
            XCTAssertEqual(drag.target, target, "\(point)")

            drag.release()
            await awaitSettle(drag)
            XCTAssertEqual(drag.ghostTopLeft, Self.miniPane.origin, "\(point)")
        }
    }

    /// A tab over its own card is a reorder, so a drop the commit seam
    /// refuses still springs the proxy back onto the thumbnail it left.
    func testATabWhoseReorderCommitsNothingSpringsBackOntoItsThumbnail() async {
        let drag = makeCoordinator()
        drag.beginIfIdle(
            .tab(Self.tab), ghost: Self.tabGhost(), at: CGPoint(x: 40, y: 80),
            home: Self.home(box: CGRect(origin: .zero, size: Self.thumbnail.size), item: .tab(Self.tab))
        )
        drag.move(to: CGPoint(x: 400, y: 180))
        XCTAssertEqual(drag.target, .tabStrip(workspace: Self.workspace, insertIndex: 1))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.thumbnail.origin)
    }

    /// Two tabs in one card, the first dragged past the second's centre: the
    /// card previews the whole post-drop arrangement, and the committed drop
    /// settles the proxy on the slot its own thumbnail slid to rather than on
    /// a bar in the strip the grid is covering.
    func testATabReorderedInsideItsCardSettlesOnTheSlotItSlidTo() async {
        let drag = makeCoordinatorWithTwoTabs(outcome: .committed)
        drag.beginIfIdle(
            .tab(Self.tab), ghost: Self.tabGhost(),
            at: CGPoint(x: Self.thumbnail.minX + 20, y: Self.thumbnail.minY + 10),
            home: Self.home(box: CGRect(origin: .zero, size: Self.thumbnail.size), item: .tab(Self.tab))
        )
        drag.move(to: CGPoint(x: Self.secondThumbnail.midX + 10, y: Self.secondThumbnail.midY))
        XCTAssertEqual(drag.target, .tabStrip(workspace: Self.workspace, insertIndex: 2))
        XCTAssertNil(drag.insertionMark, "the card opens the slot; the covered strip draws no bar")

        let slide = Self.secondThumbnail.minX - Self.thumbnail.minX
        let displacements = drag.gridTabDisplacements(inCardFor: Self.workspace)
        XCTAssertEqual(displacements[Self.tab], CGSize(width: slide, height: 0))
        XCTAssertEqual(displacements[Self.secondTab], CGSize(width: -slide, height: 0))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.secondThumbnail.origin)
    }

    /// The index is measured against where the cells REST, so a cell that has
    /// slid must never report its shifted place back in and move the very gap
    /// that shifted it.
    func testACellThatHasSlidCannotReportItsShiftedPlace() {
        let drag = makeCoordinatorWithTwoTabs(outcome: .committed)
        drag.beginIfIdle(
            .tab(Self.tab), ghost: Self.tabGhost(), at: CGPoint(x: Self.thumbnail.minX + 20, y: Self.thumbnail.minY + 10),
            home: Self.home(box: CGRect(origin: .zero, size: Self.thumbnail.size), item: .tab(Self.tab))
        )
        drag.move(to: CGPoint(x: Self.secondThumbnail.midX + 10, y: Self.secondThumbnail.midY))

        drag.setGridItemFrame(Self.thumbnail.offsetBy(dx: 110, dy: 0), for: .tab(Self.tab))
        XCTAssertEqual(
            drag.surfaces?.grid?.thumbnails.first { $0.id == Self.tab }?.frame, Self.thumbnail,
            "the reshuffled cell moved the frame the insert index is counted against"
        )
    }

    /// A tab is picked up by its handle strip, so its miniature hangs from
    /// that strip: the proxy covers the thumbnail it came from on the press
    /// and travels exactly as far as the pointer does from there. A pane
    /// proxy stays centred on the pointer, which is what keeps what the
    /// pointer is over and what the drop resolves against the same thing.
    func testATabMiniatureHangsFromTheStripItWasGrabbedBy() {
        let drag = makeCoordinator()
        let grab = CGPoint(x: Self.thumbnail.minX + 20, y: Self.thumbnail.minY + 10)
        drag.beginIfIdle(
            .tab(Self.tab), ghost: Self.tabGhost(asMiniature: true), at: grab,
            home: Self.home(box: CGRect(origin: .zero, size: Self.thumbnail.size), item: .tab(Self.tab))
        )
        XCTAssertEqual(drag.ghostTopLeft, Self.thumbnail.origin)
        drag.move(to: CGPoint(x: grab.x + 30, y: grab.y + 40))
        XCTAssertEqual(drag.ghostTopLeft, CGPoint(x: Self.thumbnail.minX + 30, y: Self.thumbnail.minY + 40))
        drag.release()

        let pane = makeCoordinator()
        pane.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size), at: CGPoint(x: 200, y: 200), home: paneHome
        )
        XCTAssertEqual(
            pane.ghostTopLeft, CGPoint(x: 200 - Self.miniPane.width / 2, y: 200 - Self.miniPane.height / 2)
        )
    }

    /// A drop commits the target under the point the button came up at, not
    /// the one under the last motion event the drag happened to see. The two
    /// differ whenever the pointer outruns the motion stream -- a synthesized
    /// drag whose steps are wider than the band being aimed at, a flick, a
    /// main thread that stalled through the last few events -- and a mini
    /// pane's edge band is only a few points inside the thumbnail's own
    /// padding, so a stale point there is a different verb: the tab's handle
    /// splits beside its focused pane, while the band composes.
    func testADropCommitsWhatIsUnderTheReleasePointNotTheLastMotion() async {
        let recorder = CommitRecorder()
        let drag = makeCoordinatorWithTwoTabs(outcome: .committed, recorder: recorder)
        drag.setGridMiniPanes(
            [MiniPaneLayout.Placed(pane: Self.secondTabPane, frame: Self.secondTabPaneBox)], for: Self.secondTab
        )
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size),
            at: CGPoint(x: Self.miniPane.midX, y: Self.miniPane.midY), home: paneHome
        )

        // The thumbnail's padding, which no mini pane covers: the last place
        // the drag is seen before it reaches the band it is aimed at.
        let short = CGPoint(
            x: Self.secondThumbnail.minX + 1,
            y: Self.secondThumbnail.minY + Self.secondTabPaneBox.midY
        )
        drag.move(to: short)
        XCTAssertEqual(drag.target, .tabThumbnail(Self.secondTab), "the approach itself is not the band")

        let released = CGPoint(
            x: Self.secondThumbnail.minX + Self.secondTabPaneBox.minX + 2,
            y: Self.secondThumbnail.minY + Self.secondTabPaneBox.midY
        )
        drag.release(at: released)
        for _ in 0..<100 where recorder.last == nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(recorder.last?.subject, .pane(Self.pane))
        XCTAssertEqual(recorder.last?.target, .paneEdge(Self.secondTabPane, .left))
    }

    /// Released in the gap between cards, where nothing resolves at all: the
    /// drop never reaches the commit seam, and the spring back is the same.
    func testAReleaseOverNothingSpringsBackTheSameWay() async {
        let drag = makeCoordinator()
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        drag.move(to: CGPoint(x: 560, y: 380))
        XCTAssertNil(drag.target)

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.miniPane.origin)
    }

    /// The grid scrolls under the drag, so the mini pane is no longer where it
    /// was when the press landed. The spring back follows the item, not the
    /// rect it once occupied.
    func testAGridThatScrollsUnderTheDragMovesWhereTheGhostSpringsBackTo() async {
        let drag = makeCoordinator()
        drag.beginIfIdle(
            .pane(Self.pane), ghost: paneGhost(originSize: Self.miniPaneBox.size),
            at: CGPoint(x: 30, y: 70), home: paneHome
        )
        drag.move(to: CGPoint(x: 90, y: 120))
        drag.setGridContentOrigin(CGPoint(x: 0, y: -120))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, CGPoint(x: Self.miniPane.minX, y: Self.miniPane.minY - 120))
    }

    /// Without a recorded home the press point stands in, which is what every
    /// drag outside the grid still does.
    func testADragWithNoRecordedHomeSpringsBackToItsPressPoint() async {
        let drag = makeCoordinator()
        let press = CGPoint(x: 30, y: 70)
        drag.beginIfIdle(.pane(Self.pane), ghost: paneGhost(originSize: Self.miniPane.size), at: press)
        drag.move(to: CGPoint(x: 560, y: 380))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, CGPoint(x: press.x - Self.miniPane.width / 2, y: press.y - Self.miniPane.height / 2))
    }
}
