import XCTest
import CoreGraphics
@testable import PaddockCore

@MainActor
private final class FakeClock {
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant { instant }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
    }
}

@MainActor
private final class CommitSpy {
    private(set) var calls: [(subject: DragSubject, target: DropTarget)] = []
    var result: DragOutcome = .committed

    func commit(_ subject: DragSubject, _ target: DropTarget) async -> DragOutcome {
        calls.append((subject, target))
        return result
    }
}

/// `fire` runs from `DragController`'s own unstructured `Task { ... }`, off
/// the calling test's synchronous stack -- `waitForFire(count:)` is what
/// gives a test a deterministic point to resume at once that task has
/// actually landed, instead of racing it with a bare assertion.
@MainActor
private final class SpringLoadSpy {
    private(set) var fired: [DropTarget] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire(_ target: DropTarget) async {
        fired.append(target)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForFire(count: Int) async {
        while fired.count < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

@MainActor
final class DragControllerTests: XCTestCase {
    private static let paneID = PaneID(rawValue: "w1:p1")
    private static let tabID = TabID(rawValue: "t1")
    private static let workspaceID = WorkspaceID(rawValue: "w2")

    /// A single pane filling the whole 600x300 canvas, plus one tab-strip
    /// item and one rail item -- enough for `resolveDropTarget` to reach
    /// every case `DragController` cares about (paneEdge, paneInterior,
    /// tabThumbnail, workspaceThumbnail, nil).
    private func surfaces() -> DropSurfaces {
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:t1"),
            zoomed: false,
            area: CellRect(x: 0, y: 0, width: 60, height: 30),
            focusedPaneID: nil,
            panes: [PaneRect(paneID: Self.paneID, focused: false, rect: CellRect(x: 0, y: 0, width: 60, height: 30))],
            splits: []
        )
        let canvas = CanvasGeometry(layout: layout, grid: CanvasGrid(canvas: CGSize(width: 600, height: 300)))
        return DropSurfaces(
            canvas: canvas,
            stripWorkspace: WorkspaceID(rawValue: "w1"),
            tabFrames: [TabItemFrame(id: Self.tabID, frame: CGRect(x: 0, y: 300, width: 100, height: 40))],
            workspaceFrames: [WorkspaceItemFrame(id: Self.workspaceID, frame: CGRect(x: -100, y: 0, width: 60, height: 100))],
            newTabZone: nil,
            newWorkspaceZone: nil
        )
    }

    private static let tabThumbnailPoint = CGPoint(x: 50, y: 320)
    private static let workspaceThumbnailPoint = CGPoint(x: -70, y: 50)
    private static let paneEdgePoint = CGPoint(x: 10, y: 150)
    private static let paneInteriorPoint = CGPoint(x: 300, y: 150)
    private static let offSurfacePoint = CGPoint(x: 5000, y: 5000)

    private func makeController(
        commit: CommitSpy, springLoad: SpringLoadSpy, clock: FakeClock
    ) -> DragController {
        DragController(commit: commit.commit, springLoadAction: springLoad.fire, now: clock.now)
    }

    // MARK: - began / moved

    func testBeganEntersDraggingWithNilTarget() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())

        controller.began(.pane(Self.paneID), at: Self.paneInteriorPoint)

        XCTAssertEqual(controller.phase, .dragging(.pane(Self.paneID), ghostPosition: Self.paneInteriorPoint, target: nil))
    }

    func testMovedSetsTargetFromTheResolver() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())

        XCTAssertEqual(
            controller.phase,
            .dragging(.pane(Self.paneID), ghostPosition: Self.paneInteriorPoint, target: .paneInterior(Self.paneID))
        )
    }

    func testMovedBeforeBeganIsIgnored() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())

        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - spring load arming

    func testMovedOverTabThumbnailArmsSpringLoadWithA500msDeadline() {
        let clock = FakeClock()
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: clock)
        controller.began(.pane(Self.paneID), at: .zero)

        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        XCTAssertEqual(controller.springLoad?.target, .tabThumbnail(Self.tabID))
        XCTAssertEqual(controller.springLoad?.deadline, clock.now().advanced(by: .milliseconds(500)))
    }

    func testMovedOverWorkspaceThumbnailArmsSpringLoad() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.moved(to: Self.workspaceThumbnailPoint, surfaces: surfaces())

        XCTAssertEqual(controller.springLoad?.target, .workspaceThumbnail(Self.workspaceID))
    }

    func testMovedOverPaneEdgeDoesNotArmSpringLoad() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.moved(to: Self.paneEdgePoint, surfaces: surfaces())

        XCTAssertEqual(controller.phase, .dragging(.pane(Self.paneID), ghostPosition: Self.paneEdgePoint, target: .paneEdge(Self.paneID, .left)))
        XCTAssertNil(controller.springLoad)
    }

    func testMovedOverPaneInteriorDoesNotArmSpringLoad() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())

        XCTAssertNil(controller.springLoad)
    }

    func testMovingAwayFromAnArmedTargetClearsSpringLoad() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        XCTAssertNotNil(controller.springLoad)

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())

        XCTAssertNil(controller.springLoad)
    }

    func testMovingWithinTheSameTargetKeepsTheOriginalDeadline() {
        let clock = FakeClock()
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: clock)
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        let originalDeadline = controller.springLoad?.deadline

        clock.advance(by: .milliseconds(200))
        let jitteredPoint = CGPoint(x: Self.tabThumbnailPoint.x + 1, y: Self.tabThumbnailPoint.y)
        controller.moved(to: jitteredPoint, surfaces: surfaces())

        XCTAssertEqual(controller.springLoad?.target, .tabThumbnail(Self.tabID))
        XCTAssertEqual(controller.springLoad?.deadline, originalDeadline)
    }

    // MARK: - spring load firing

    func testSpringLoadFiresOnTheNextMovedCallOnceTheDeadlinePasses() async {
        let clock = FakeClock()
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: clock)
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        XCTAssertTrue(springLoad.fired.isEmpty)

        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await springLoad.waitForFire(count: 1)

        XCTAssertEqual(springLoad.fired, [.tabThumbnail(Self.tabID)])
        XCTAssertEqual(controller.phase.target, .tabThumbnail(Self.tabID), "firing does not end the drag")
    }

    func testSpringLoadDoesNotRefireWithoutLeavingTheTarget() async {
        let clock = FakeClock()
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: clock)
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await springLoad.waitForFire(count: 1)
        XCTAssertEqual(springLoad.fired.count, 1)

        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        XCTAssertEqual(springLoad.fired.count, 1)
    }

    func testLeavingAndReturningToTheSameTargetRearmsAndCanRefire() async {
        let clock = FakeClock()
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: clock)
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await springLoad.waitForFire(count: 1)
        XCTAssertEqual(springLoad.fired.count, 1)

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await springLoad.waitForFire(count: 2)

        XCTAssertEqual(springLoad.fired.count, 2)
    }

    func testForceSpringLoadFiresBeforeTheDeadline() async {
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        controller.forceSpringLoad()
        await springLoad.waitForFire(count: 1)

        XCTAssertEqual(springLoad.fired, [.tabThumbnail(Self.tabID)])
    }

    func testForceSpringLoadFiresExactlyOnceWhenCalledTwice() async {
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        controller.forceSpringLoad()
        await springLoad.waitForFire(count: 1)
        controller.forceSpringLoad()

        XCTAssertEqual(springLoad.fired.count, 1)
    }

    func testForceSpringLoadWithNothingArmedDoesNothing() {
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.forceSpringLoad()

        XCTAssertTrue(springLoad.fired.isEmpty)
    }

    // MARK: - ended

    func testEndedWithNoTargetReturnsToIdleWithoutCallingCommit() async {
        let commit = CommitSpy()
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.offSurfacePoint, surfaces: surfaces())
        XCTAssertNil(controller.phase.target)

        await controller.ended()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(commit.calls.isEmpty)
    }

    func testEndedWithAValidTargetCommitsAndReturnsToIdleOnCommitted() async {
        let commit = CommitSpy()
        commit.result = .committed
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        await controller.ended()

        XCTAssertEqual(commit.calls.count, 1)
        XCTAssertEqual(commit.calls.first?.subject, .pane(Self.paneID))
        XCTAssertEqual(commit.calls.first?.target, .tabThumbnail(Self.tabID))
        XCTAssertEqual(controller.phase, .idle)
    }

    func testEndedWithANoOpOutcomeReturnsToIdleWithoutRejection() async {
        let commit = CommitSpy()
        commit.result = .noOp
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        await controller.ended()

        XCTAssertEqual(controller.phase, .idle)
    }

    func testEndedWithARejectedOutcomeEntersRejectedPhase() async {
        let commit = CommitSpy()
        commit.result = .rejected("Can't move there")
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        await controller.ended()

        XCTAssertEqual(controller.phase, .rejected(reason: "Can't move there"))
    }

    func testEndedWhileIdleIsANoOp() async {
        let commit = CommitSpy()
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())

        await controller.ended()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(commit.calls.isEmpty)
    }

    // MARK: - cancelled

    func testCancelledFromDraggingReturnsToIdleAndIssuesNoCommits() {
        let commit = CommitSpy()
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        controller.cancelled()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.springLoad)
        XCTAssertTrue(commit.calls.isEmpty)
    }

    func testCancelledFromRejectedReturnsToIdle() async {
        let commit = CommitSpy()
        commit.result = .rejected("nope")
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await controller.ended()
        XCTAssertEqual(controller.phase, .rejected(reason: "nope"))

        controller.cancelled()

        XCTAssertEqual(controller.phase, .idle)
    }

    func testCancelledFromCommittingReturnsToIdle() {
        let controller = makeController(commit: CommitSpy(), springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.cancelled()

        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - began after rejected

    func testBeganFromRejectedIsLegalAndStartsAFreshDrag() async {
        let commit = CommitSpy()
        commit.result = .rejected("nope")
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await controller.ended()
        XCTAssertEqual(controller.phase, .rejected(reason: "nope"))

        controller.began(.pane(Self.paneID), at: Self.paneInteriorPoint)

        XCTAssertEqual(controller.phase, .dragging(.pane(Self.paneID), ghostPosition: Self.paneInteriorPoint, target: nil))
    }
}

private extension DragController.Phase {
    var target: DropTarget? {
        guard case .dragging(_, _, let target) = self else { return nil }
        return target
    }
}
