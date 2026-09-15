import PaddockCore
import XCTest

/// The coordinator's half of the strip's scrolling: the running total a wheel
/// burst accumulates against, and the reveal that has to wait for a tab's
/// frame. The decisions themselves are `TabStripScrollGeometry`'s.
@MainActor
final class TabStripScrollCoordinatorTests: XCTestCase {
    private static let first = TabID(rawValue: "w1:t1")
    private static let created = TabID(rawValue: "w1:t9")
    private static let viewport = CGRect(x: 200, y: 26, width: 400, height: 36)

    private func makeCoordinator() -> DragCoordinator {
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { _, _ in .noOp }, reveal: { _ in }
        )
        drag.stripWorkspace = WorkspaceID(rawValue: "w1")
        drag.stripViewport = Self.viewport
        drag.setStripScroll(offset: 0, maximumOffset: 600)
        return drag
    }

    /// The strip reports its offset back a render pass late, so three events
    /// inside one frame all read the same stale zero. Each has to add to the
    /// last instead of replacing it.
    func testAWheelBurstInsideOneFrameAccumulatesRatherThanCoalescing() {
        let drag = makeCoordinator()
        var scrolledTo: [CGFloat] = []
        drag.stripScroller = { scrolledTo.append($0) }

        for _ in 0..<3 {
            drag.stripWheelScrolled(deltaX: 0, deltaY: -10, precise: true)
        }

        XCTAssertEqual(scrolledTo, [10, 20, 30])
    }

    /// Once the strip's own report catches up there is nothing left to carry,
    /// and the next event starts from what the strip actually says.
    func testAReportThatCatchesUpEndsTheRunningTotal() {
        let drag = makeCoordinator()
        var scrolledTo: [CGFloat] = []
        drag.stripScroller = { scrolledTo.append($0) }

        drag.stripWheelScrolled(deltaX: 0, deltaY: -10, precise: true)
        drag.setStripScroll(offset: 10, maximumOffset: 600)
        drag.stripWheelScrolled(deltaX: 0, deltaY: -10, precise: true)

        XCTAssertEqual(scrolledTo, [10, 20])
    }

    /// The strip's content changed under the wheel, so the run it was counting
    /// against is gone and the total starts again from the report.
    func testAChangedRunAbandonsTheRunningTotal() {
        let drag = makeCoordinator()
        var scrolledTo: [CGFloat] = []
        drag.stripScroller = { scrolledTo.append($0) }

        drag.stripWheelScrolled(deltaX: 0, deltaY: -100, precise: true)
        drag.setStripScroll(offset: 0, maximumOffset: 200)
        drag.stripWheelScrolled(deltaX: 0, deltaY: -10, precise: true)

        XCTAssertEqual(scrolledTo, [100, 10])
    }

    /// A classic wheel counts lines, so one notch has to be worth a tab.
    func testAWheelNotchMovesTheStripByAWholeTab() {
        let drag = makeCoordinator()
        var scrolledTo: [CGFloat] = []
        drag.stripScroller = { scrolledTo.append($0) }

        drag.stripWheelScrolled(deltaX: 0, deltaY: -1, precise: false)

        XCTAssertEqual(scrolledTo, [ChromeMetrics.Strip.wheelLineStep])
    }

    /// The strip's frames outlive it under a shown grid, so the wheel has to
    /// check the grid rather than the frames.
    func testAWheelIsNotTheStripsWhileTheGridCoversIt() {
        let drag = makeCoordinator()
        var scrolledTo: [CGFloat] = []
        drag.stripScroller = { scrolledTo.append($0) }
        drag.toggleGrid()

        drag.revealTab(Self.first)
        XCTAssertTrue(scrolledTo.isEmpty)
    }

    /// A tab is selected in the same update pass that inserts it, so its frame
    /// has not been reported yet. The reveal has to survive until it is.
    func testARevealAskedForBeforeTheTabHasAFrameIsRetriedWhenItArrives() {
        let drag = makeCoordinator()
        var revealedTo: [CGFloat] = []
        drag.stripRevealScroller = { revealedTo.append($0) }
        drag.setTabOrder([Self.first, Self.created])
        drag.setTabFrame(CGRect(x: 0, y: 0, width: 100, height: 28), for: Self.first)

        drag.revealTab(Self.created)
        XCTAssertTrue(revealedTo.isEmpty, "nothing to scroll to yet")

        drag.setTabFrame(CGRect(x: 800, y: 0, width: 100, height: 28), for: Self.created)
        XCTAssertEqual(revealedTo, [500], "its trailing edge brought to the viewport's")
    }

    /// The retry is spent once it lands: later frame reports must not scroll
    /// the strip again behind the user.
    func testARevealThatLandsIsNotRetriedAgain() {
        let drag = makeCoordinator()
        var revealedTo: [CGFloat] = []
        drag.stripRevealScroller = { revealedTo.append($0) }
        drag.setTabOrder([Self.first, Self.created])

        drag.revealTab(Self.created)
        drag.setTabFrame(CGRect(x: 800, y: 0, width: 100, height: 28), for: Self.created)
        drag.setStripScroll(offset: 500, maximumOffset: 600)
        drag.setTabFrame(CGRect(x: 810, y: 0, width: 100, height: 28), for: Self.created)

        XCTAssertEqual(revealedTo, [500])
    }
}
