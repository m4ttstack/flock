import PaddockCore
import XCTest

/// `DragCoordinator.beginIfIdle`'s rail-offset nudge for a starting pane
/// drag: the one piece of the entry-row margin fix that cannot live in
/// `PaddockCoreTests` because it drives the coordinator's own `railScroller`
/// hook rather than a pure function.
@MainActor
final class RailDragScrollTests: XCTestCase {
    private static let paneID = PaneID(rawValue: "w1:p1")
    private static let tabID = TabID(rawValue: "w1:t1")
    private static let ghost = DragCoordinator.Ghost(title: "t", symbol: "s", originSize: .zero)

    private func makeCoordinator() -> DragCoordinator {
        DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { _, _ in fatalError("not exercised") }, reveal: { _ in }
        )
    }

    func testAPaneDragBeginningWithTheRailAtItsMaximumNudgesItByTheEntryRowMargin() {
        let drag = makeCoordinator()
        drag.setRailScroll(offset: 300, maximumOffset: 300)
        var scrolledTo: [CGFloat] = []
        drag.railScroller = { scrolledTo.append($0) }

        drag.beginIfIdle(.pane(Self.paneID), ghost: Self.ghost, at: .zero)

        XCTAssertEqual(scrolledTo, [300 + WorkspaceRail.entryRowMarginDelta])
    }

    func testAPaneDragBeginningWithSlackLeftInTheRailLeavesItsOffsetAlone() {
        let drag = makeCoordinator()
        drag.setRailScroll(offset: 100, maximumOffset: 300)
        var scrolledTo: [CGFloat] = []
        drag.railScroller = { scrolledTo.append($0) }

        drag.beginIfIdle(.pane(Self.paneID), ghost: Self.ghost, at: .zero)

        XCTAssertTrue(scrolledTo.isEmpty)
    }

    func testATabDragNeverTouchesTheRailScroller() {
        let drag = makeCoordinator()
        drag.setRailScroll(offset: 300, maximumOffset: 300)
        var scrolledTo: [CGFloat] = []
        drag.railScroller = { scrolledTo.append($0) }

        drag.beginIfIdle(.tab(Self.tabID), ghost: Self.ghost, at: .zero)

        XCTAssertTrue(scrolledTo.isEmpty)
    }
}
