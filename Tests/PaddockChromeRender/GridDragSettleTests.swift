import PaddockCore
import XCTest

/// Where the ghost goes when a grid drop commits nothing. The decision itself
/// is `DragVisuals.settleHomeTopLeft`; this drives the coordinator that feeds
/// it, which is the half `PaddockCoreTests` cannot reach.
@MainActor
final class GridDragSettleTests: XCTestCase {
    private static let workspace = WorkspaceID(rawValue: "w1")
    private static let tab = TabID(rawValue: "w1:t1")
    private static let pane = PaneID(rawValue: "w1:p1")
    private static let card = CGRect(x: 10, y: 10, width: 500, height: 200)
    private static let thumbnail = CGRect(x: 20, y: 60, width: 100, height: 82)
    /// One mini pane inside the thumbnail, stated in the thumbnail's space.
    private static let miniPaneBox = CGRect(x: 4, y: 4, width: 45, height: 74)
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

    /// A shown grid with one card and one thumbnail, assembled from frame
    /// reports rather than from a window.
    private func makeCoordinator(outcome: DragOutcome = .noOp) -> DragCoordinator {
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { _, _ in outcome }, reveal: { _ in }
        )
        drag.stripWorkspace = Self.workspace
        drag.toggleGrid()
        drag.gridViewport = CGRect(x: 0, y: 0, width: 600, height: 400)
        drag.setGridOrder([.card(Self.workspace), .tab(Self.tab)])
        drag.setGridItemFrame(Self.card, for: .card(Self.workspace))
        drag.setGridItemFrame(Self.thumbnail, for: .tab(Self.tab))
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
            .tab(Self.tab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: Self.thumbnail.size, isCompact: true
            ),
            at: CGPoint(x: 40, y: 80),
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

        drag.beginIfIdle(
            .tab(Self.tab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: Self.thumbnail.size, isCompact: true
            ),
            at: CGPoint(x: 40, y: 80)
        )
        XCTAssertFalse(drag.holdsGrabCursor)
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
        drag.move(to: CGPoint(x: 90, y: 120))
        XCTAssertEqual(drag.target, .tabThumbnail(Self.tab))

        drag.release()
        await awaitSettle(drag)
        XCTAssertTrue(drag.isSettling)
        XCTAssertEqual(drag.ghostTopLeft, Self.miniPane.origin)
    }

    func testATabDroppedOnItsOwnWorkspacesCardSpringsBackOntoItsThumbnail() async {
        let drag = makeCoordinator()
        drag.beginIfIdle(
            .tab(Self.tab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: Self.thumbnail.size, isCompact: true
            ),
            at: CGPoint(x: 40, y: 80),
            home: Self.home(box: CGRect(origin: .zero, size: Self.thumbnail.size), item: .tab(Self.tab))
        )
        drag.move(to: CGPoint(x: 400, y: 180))
        XCTAssertEqual(drag.target, .workspaceThumbnail(Self.workspace))

        drag.release()
        await awaitSettle(drag)
        XCTAssertEqual(drag.ghostTopLeft, Self.thumbnail.origin)
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
