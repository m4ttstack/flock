import XCTest
import CoreGraphics
@testable import FlockCore

/// Records what a drag commits, in full: the same values
/// `SessionViewModel.setSplitRatio` receives.
@MainActor
private final class CommitLog {
    private(set) var entries: [(tabID: TabID, path: [Bool], ratio: Double)] = []

    func append(_ tabID: TabID, _ path: [Bool], _ ratio: Double) {
        entries.append((tabID, path, ratio))
    }
}

/// A divider drag driven the way the view drives it: a real `DividerHandle`
/// taken out of the canvas geometry, a sequence of canvas-local pointer
/// positions through `DividerDragSession`, and the boundary read back out of
/// the geometry the canvas paints from. `DividerHandleView` adds nothing to
/// that but the callbacks (a begin on the first change, a move per change, an
/// end on release) and `DividerDragCoordinator` the cursor and the monitors,
/// so this is the whole of the path a pointer travels.
///
/// The fixture is deliberately coarse-grained: 24 herdr cells across 1200pt,
/// so one cell is 50pt and every pointer below sits at least 12pt from the
/// nearest cell edge. A boundary placed on the cell grid instead of at the
/// pointer misses by that much.
final class DividerDragPointerPathTests: XCTestCase {
    private let tabID = TabID(rawValue: "w:t")
    private let area = CellRect(x: 0, y: 0, width: 24, height: 8)
    private let canvas = CGSize(width: 1200, height: 400)

    private var tree: ExportedLayoutNode {
        .split(
            direction: .right, ratio: 0.5,
            first: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "left"))),
            second: .pane(ExportedLayoutPane(paneID: PaneID(rawValue: "right")))
        )
    }

    private func geometry(liveRatio: Double? = nil) -> CanvasGeometry {
        CanvasGeometry(
            exportedRoot: tree, area: area, tabID: tabID,
            grid: CanvasGrid(canvas: canvas, displayScale: 2),
            dividerThickness: DividerBand.gutter,
            liveRatioOverride: liveRatio.map { (path: [], ratio: $0) }
        )
    }

    @MainActor
    private func makeSession(_ log: CommitLog) -> DividerDragSession {
        DividerDragSession { tabID, path, ratio in log.append(tabID, path, ratio) }
    }

    /// Every reported pointer position puts the boundary under the pointer,
    /// and the release commits that last position once -- not one commit per
    /// frame, and not the ratio the press started from.
    @MainActor
    func testEveryPointerPositionPutsTheBoundaryUnderItAndTheReleaseCommitsTheLastOne() async throws {
        let log = CommitLog()
        let session = makeSession(log)
        let divider = try XCTUnwrap(geometry().dividers.first)
        XCTAssertTrue(session.began(divider))

        var live: (tabID: TabID, path: [Bool], ratio: Double)?
        for x in [425.0, 473.0, 622.0, 738.0] {
            session.moved(to: CGPoint(x: x, y: divider.regionFrame.midY), for: divider)
            live = try XCTUnwrap(session.liveOverride)
            XCTAssertEqual(live?.tabID, divider.tabID)
            XCTAssertEqual(live?.path, divider.path)

            let painted = try XCTUnwrap(geometry(liveRatio: try XCTUnwrap(live?.ratio)).dividers.first)
            XCTAssertEqual(
                painted.boundaryPoint.x, x, accuracy: 0.01,
                "the boundary did not follow the pointer to \(x)")
            let left = try XCTUnwrap(geometry(liveRatio: try XCTUnwrap(live?.ratio)).paneFrames[PaneID(rawValue: "left")])
            XCTAssertEqual(left.maxX, x, accuracy: 0.01, "the pane box stopped short of its own boundary")
        }
        XCTAssertTrue(log.entries.isEmpty, "a move committed before the release")

        XCTAssertTrue(session.ended())
        await session.pendingCommit?.value

        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.tabID, divider.tabID)
        XCTAssertEqual(log.entries.first?.path, divider.path)
        XCTAssertEqual(try XCTUnwrap(log.entries.first?.ratio), 738.0 / 1200.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(log.entries.first?.ratio), try XCTUnwrap(live?.ratio), accuracy: 0.000_001)
    }

    /// A pointer dragged past the point where herdr's own per-pane floor
    /// would start enlarging a pane behind flock's back stops at that
    /// floor, on screen and in what the release commits.
    @MainActor
    func testAPointerDraggedPastThePaneFloorStopsThereAndCommitsWhereItStopped() async throws {
        let log = CommitLog()
        let session = makeSession(log)
        let divider = try XCTUnwrap(geometry().dividers.first)
        XCTAssertTrue(session.began(divider))

        // Four columns of a 24-column region is the floor, so the boundary
        // can reach 20 columns: 1000 of the 1200 points.
        session.moved(to: CGPoint(x: 1190, y: divider.regionFrame.midY), for: divider)

        let live = try XCTUnwrap(session.liveOverride)
        let painted = try XCTUnwrap(geometry(liveRatio: live.ratio).dividers.first)
        XCTAssertEqual(painted.boundaryPoint.x, 1000, accuracy: 0.01, "the boundary ran past the floor")

        XCTAssertTrue(session.ended())
        await session.pendingCommit?.value

        XCTAssertEqual(try XCTUnwrap(log.entries.first?.ratio), 1000.0 / 1200.0, accuracy: 0.0001)
    }

    /// The release commits where the button came up, not where the last
    /// motion report left the boundary. Motion is coalesced and can be
    /// outrun -- a flick, a main thread that stalled through the last few
    /// events -- so the two are different points, and the pointer's own is the
    /// one the hand chose.
    @MainActor
    func testTheReleaseCommitsItsOwnPointRatherThanTheLastMotionReport() async throws {
        let log = CommitLog()
        let session = makeSession(log)
        let divider = try XCTUnwrap(geometry().dividers.first)
        XCTAssertTrue(session.began(divider))
        session.moved(to: CGPoint(x: 473, y: divider.regionFrame.midY), for: divider)

        XCTAssertTrue(session.ended(at: CGPoint(x: 738, y: divider.regionFrame.midY), for: divider))
        await session.pendingCommit?.value

        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(try XCTUnwrap(log.entries.first?.ratio), 738.0 / 1200.0, accuracy: 0.0001)
    }

    /// The release point carries the same guard its motion reports carry:
    /// measured against another divider's region, it names a boundary the
    /// dragged divider never had.
    @MainActor
    func testAReleasePointFromAnotherDividerLeavesTheCommitWhereTheDragWas() async throws {
        let log = CommitLog()
        let session = makeSession(log)
        let divider = try XCTUnwrap(geometry().dividers.first)
        XCTAssertTrue(session.began(divider))
        session.moved(to: CGPoint(x: 473, y: divider.regionFrame.midY), for: divider)

        let other = DividerHandle(
            tabID: tabID, path: [true],
            frame: divider.frame, direction: .right,
            regionFrame: divider.regionFrame, cellExtent: divider.cellExtent
        )
        XCTAssertTrue(session.ended(at: CGPoint(x: 900, y: divider.regionFrame.midY), for: other))
        await session.pendingCommit?.value

        XCTAssertEqual(try XCTUnwrap(log.entries.first?.ratio), 473.0 / 1200.0, accuracy: 0.0001)
    }

    /// Each divider's own view reports into the one session, so a report that
    /// arrives from a divider that is not the one being dragged carries a
    /// pointer measured against a different region. Taking it would move the
    /// dragged boundary somewhere the pointer never was.
    @MainActor
    func testAPointerReportFromAnotherDividerNeverMovesTheDraggedBoundary() async throws {
        let log = CommitLog()
        let session = makeSession(log)
        let divider = try XCTUnwrap(geometry().dividers.first)
        XCTAssertTrue(session.began(divider))
        session.moved(to: CGPoint(x: 473, y: divider.regionFrame.midY), for: divider)
        let dragged = try XCTUnwrap(session.liveOverride)

        let other = DividerHandle(
            tabID: tabID, path: [true],
            frame: divider.frame, direction: .right,
            regionFrame: divider.regionFrame, cellExtent: divider.cellExtent
        )
        session.moved(to: CGPoint(x: 900, y: divider.regionFrame.midY), for: other)

        XCTAssertEqual(try XCTUnwrap(session.liveOverride?.ratio), dragged.ratio, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(session.liveOverride?.path), divider.path)

        XCTAssertTrue(session.ended())
        await session.pendingCommit?.value
        XCTAssertEqual(try XCTUnwrap(log.entries.first?.ratio), 473.0 / 1200.0, accuracy: 0.0001)
    }
}
