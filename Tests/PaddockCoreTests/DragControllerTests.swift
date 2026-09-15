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

/// Polls `condition` via cooperative yields, never a real timer, until it is
/// true or `maxYields` is exhausted. Bounds a wait for something that runs
/// from `DragController`'s own fire-and-forget `Task`s (spring load actions,
/// and `commit` itself) so a regression that stops it running fails fast
/// instead of hanging the suite for XCTest's default 600 seconds.
@MainActor
private func poll(maxYields: Int = 10_000, until condition: () -> Bool) async {
    var yields = 0
    while !condition(), yields < maxYields {
        await Task.yield()
        yields += 1
    }
}

/// `hold()`/`release()` suspend `commit` on a continuation the test controls,
/// so a test can drive the controller into `.committing` and keep it there
/// deterministically instead of racing the commit's own completion.
@MainActor
private final class CommitSpy {
    private(set) var calls: [(subject: DragSubject, target: DropTarget)] = []
    var result: DragOutcome = .committed

    private var holdEnabled = false
    private var holdContinuation: CheckedContinuation<Void, Never>?

    func hold() { holdEnabled = true }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }

    func commit(_ subject: DragSubject, _ target: DropTarget) async -> DragOutcome {
        calls.append((subject, target))
        if holdEnabled {
            await withCheckedContinuation { holdContinuation = $0 }
        }
        return result
    }

    func waitForCall(count: Int) async {
        await poll { self.calls.count >= count }
    }
}

@MainActor
private final class SpringLoadSpy {
    private(set) var fired: [DropTarget] = []

    func fire(_ target: DropTarget) {
        fired.append(target)
    }

    func waitForFire(count: Int) async {
        await poll { self.fired.count >= count }
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
        DragController(commit: commit.commit, onSpringLoad: springLoad.fire, now: clock.now)
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

    func testMovedIsIgnoredWhileCommitting() async {
        let commit = CommitSpy()
        commit.hold()
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        let endedTask = Task { await controller.ended() }
        await commit.waitForCall(count: 1)
        XCTAssertEqual(controller.phase, .committing)

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())

        XCTAssertEqual(controller.phase, .committing, "a commit already captured its target; a later move must not change it")

        commit.release()
        await endedTask.value
    }

    func testMovedIsIgnoredWhileRejected() async {
        let commit = CommitSpy()
        commit.result = .rejected("Can't move there")
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        await controller.ended()
        XCTAssertEqual(controller.phase, .rejected(reason: "Can't move there"))

        controller.moved(to: Self.paneInteriorPoint, surfaces: surfaces())

        XCTAssertEqual(controller.phase, .rejected(reason: "Can't move there"))
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

    /// The two dwell-only targets: the rail's "All workspaces" row opens the
    /// grid, and a card's +N tile expands it. Each arms like a thumbnail and
    /// fires once its 500ms are up.
    func testDwellingOnTheRailEntryThenAPlusTileFiresBothSpringLoads() async {
        let clock = FakeClock()
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: clock)
        let withEntry = DropSurfaces(
            canvas: .empty, stripWorkspace: WorkspaceID(rawValue: "w1"), tabFrames: [], workspaceFrames: [],
            newTabZone: nil, newWorkspaceZone: nil, allWorkspacesEntry: CGRect(x: -100, y: 400, width: 60, height: 20)
        )
        let grid = DropSurfaces(
            canvas: .empty, stripWorkspace: WorkspaceID(rawValue: "w1"), tabFrames: [], workspaceFrames: [],
            newTabZone: nil, newWorkspaceZone: nil,
            grid: GridDropSurfaces(
                viewport: CGRect(x: 0, y: 0, width: 600, height: 300), thumbnails: [],
                moreTiles: [WorkspaceItemFrame(id: Self.workspaceID, frame: CGRect(x: 10, y: 10, width: 80, height: 80))]
            )
        )
        controller.began(.pane(Self.paneID), at: .zero)

        controller.moved(to: CGPoint(x: -70, y: 410), surfaces: withEntry)
        XCTAssertEqual(controller.springLoad?.target, .allWorkspaces)
        clock.advance(by: .milliseconds(500))
        controller.moved(to: CGPoint(x: -69, y: 410), surfaces: withEntry)
        await springLoad.waitForFire(count: 1)

        controller.moved(to: CGPoint(x: 50, y: 50), surfaces: grid)
        XCTAssertEqual(controller.springLoad?.target, .moreTabs(Self.workspaceID))
        clock.advance(by: .milliseconds(500))
        controller.moved(to: CGPoint(x: 51, y: 50), surfaces: grid)
        await springLoad.waitForFire(count: 2)

        XCTAssertEqual(springLoad.fired, [.allWorkspaces, .moreTabs(Self.workspaceID)])
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

    func testBeganResetsASpringLoadThatHadAlreadyFiredFromThePreviousDrag() async {
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        controller.forceSpringLoad()
        await springLoad.waitForFire(count: 1)
        XCTAssertEqual(springLoad.fired.count, 1)

        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        controller.forceSpringLoad()
        await springLoad.waitForFire(count: 2)

        XCTAssertEqual(springLoad.fired.count, 2, "the second drag's dwell over the same target must fire its own Space press")
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
        // Waits for a fire that a correct controller will never produce, so
        // this genuinely gives a regression the chance to land before the
        // assertion below runs -- see `poll`'s doc comment.
        await springLoad.waitForFire(count: 2)

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

    /// No await anywhere: the hook must already have run when `moved` returns,
    /// or a caller stopping work on it gets one more frame first.
    func testOnSpringLoadRunsInsideTheMovedCallThatFiresAndOnlyOnce() {
        let clock = FakeClock()
        var hooked: [DropTarget] = []
        let controller = DragController(
            commit: CommitSpy().commit,
            onSpringLoad: { hooked.append($0) }, now: clock.now
        )
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        XCTAssertEqual(hooked, [])

        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        XCTAssertEqual(hooked, [.tabThumbnail(Self.tabID)])

        clock.advance(by: .milliseconds(500))
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        XCTAssertEqual(hooked.count, 1)
    }

    func testOnSpringLoadRunsInsideForceSpringLoad() {
        var hooked: [DropTarget] = []
        let controller = DragController(
            commit: CommitSpy().commit,
            onSpringLoad: { hooked.append($0) }, now: FakeClock().now
        )
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        controller.forceSpringLoad()

        XCTAssertEqual(hooked, [.tabThumbnail(Self.tabID)])
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
        // Waits for a second fire a correct controller will never produce.
        await springLoad.waitForFire(count: 2)

        XCTAssertEqual(springLoad.fired.count, 1)
    }

    func testForceSpringLoadWithNothingArmedDoesNothing() async {
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: CommitSpy(), springLoad: springLoad, clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)

        controller.forceSpringLoad()
        await springLoad.waitForFire(count: 1)

        XCTAssertTrue(springLoad.fired.isEmpty)
    }

    func testForceSpringLoadDoesNothingWhileCommittingEvenThoughSpringLoadIsStillArmed() async {
        let commit = CommitSpy()
        commit.hold()
        let springLoad = SpringLoadSpy()
        let controller = makeController(commit: commit, springLoad: springLoad, clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())
        XCTAssertNotNil(controller.springLoad)

        let endedTask = Task { await controller.ended() }
        await commit.waitForCall(count: 1)
        XCTAssertEqual(controller.phase, .committing)
        XCTAssertNotNil(controller.springLoad, "not cleared until the commit resolves")

        controller.forceSpringLoad()
        await springLoad.waitForFire(count: 1)

        XCTAssertTrue(springLoad.fired.isEmpty, "a reveal action with no drag on screen would be observable nonsense")

        commit.release()
        await endedTask.value
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
        XCTAssertNotNil(controller.springLoad)

        await controller.ended()

        XCTAssertEqual(commit.calls.count, 1)
        XCTAssertEqual(commit.calls.first?.subject, .pane(Self.paneID))
        XCTAssertEqual(commit.calls.first?.target, .tabThumbnail(Self.tabID))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.springLoad, "idle must never carry an armed spring load")
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

    func testEndedWithANotAttemptedOutcomeReturnsToIdleWithoutRejection() async {
        let commit = CommitSpy()
        commit.result = .notAttempted
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

    // MARK: - re-entrancy: a stale ended() completion must not clobber a later phase

    func testCancelDuringAnInFlightCommitDiscardsTheStaleRejectedWriteOnResume() async {
        let commit = CommitSpy()
        commit.hold()
        commit.result = .rejected("Can't move there")
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        let endedTask = Task { await controller.ended() }
        await commit.waitForCall(count: 1)

        controller.cancelled()
        commit.release()
        await endedTask.value

        XCTAssertEqual(controller.phase, .idle, "a commit resolving after cancel must not reopen a rejection banner")
    }

    func testANewDragStartedWhileAnEarlierCommitIsInFlightSurvivesThatCommitsLateWrite() async {
        let commit = CommitSpy()
        commit.hold()
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        let endedTask = Task { await controller.ended() }
        await commit.waitForCall(count: 1)

        let secondStart = CGPoint(x: 1, y: 1)
        controller.began(.pane(Self.paneID), at: secondStart)
        commit.release()
        await endedTask.value

        XCTAssertEqual(
            controller.phase,
            .dragging(.pane(Self.paneID), ghostPosition: secondStart, target: nil),
            "the first gesture's late commit must not clobber the second gesture already in flight"
        )
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

    /// Also the one spot in this file that genuinely reaches `.committing`:
    /// a held commit is what makes that phase observable rather than
    /// assumed, and deleting `phase = .committing` in `ended()` fails the
    /// first assertion below rather than passing vacuously.
    func testCancelledFromCommittingReturnsToIdle() async {
        let commit = CommitSpy()
        commit.hold()
        let controller = makeController(commit: commit, springLoad: SpringLoadSpy(), clock: FakeClock())
        controller.began(.pane(Self.paneID), at: .zero)
        controller.moved(to: Self.tabThumbnailPoint, surfaces: surfaces())

        let endedTask = Task { await controller.ended() }
        await commit.waitForCall(count: 1)
        XCTAssertEqual(controller.phase, .committing)

        controller.cancelled()

        XCTAssertEqual(controller.phase, .idle)

        commit.release()
        await endedTask.value
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
