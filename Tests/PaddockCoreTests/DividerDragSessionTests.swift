import XCTest
import CoreGraphics
@testable import PaddockCore

/// Records what a `DividerDragSession` owes as its gestures end. `commit` can
/// be held open so a test can look between a release and its commit landing.
@MainActor
private final class GestureEndRecorder {
    private(set) var commits: [Double] = []
    var settles = 0
    var holdCommits = false
    private var pending: CheckedContinuation<Void, Never>?

    func commit(_ ratio: Double) async {
        commits.append(ratio)
        if holdCommits {
            await withCheckedContinuation { pending = $0 }
        }
    }

    func releaseCommit() {
        pending?.resume()
        pending = nil
    }
}

final class DividerDragSessionTests: XCTestCase {
    private static let region = CGRect(x: 0, y: 0, width: 600, height: 300)

    private static let divider: DividerHandle = {
        let boundaryX = region.minX + 0.5 * region.width
        return DividerHandle(
            tabID: TabID(rawValue: "w:t"), path: [],
            frame: CGRect(x: boundaryX - 3, y: region.minY, width: 6, height: region.height),
            direction: .right, regionFrame: region, cellExtent: 1000)
    }()

    private static let movedPointer = CGPoint(x: 180, y: region.midY)

    @MainActor
    private func makeSession(_ recorder: GestureEndRecorder) -> DividerDragSession {
        DividerDragSession(
            commit: { _, _, ratio in await recorder.commit(ratio) },
            settle: { recorder.settles += 1 }
        )
    }

    @MainActor
    func testAReleaseAfterARealMoveSettlesOnceItsCommitLands() async {
        let recorder = GestureEndRecorder()
        recorder.holdCommits = true
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)

        XCTAssertTrue(session.ended())
        for _ in 0..<1_000 where recorder.commits.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertEqual(recorder.settles, 0, "the geometry is not final until the commit lands")
        XCTAssertNotNil(session.liveOverride)

        recorder.releaseCommit()
        await session.pendingCommit?.value

        XCTAssertEqual(recorder.settles, 1)
        XCTAssertNil(session.liveOverride)
    }

    @MainActor
    func testAReleaseWithNoMoveSettlesOnceAndCommitsNothing() {
        let recorder = GestureEndRecorder()
        let session = makeSession(recorder)
        session.began(Self.divider)

        XCTAssertTrue(session.ended())

        XCTAssertEqual(recorder.settles, 1)
        XCTAssertTrue(recorder.commits.isEmpty)
    }

    @MainActor
    func testEscSettlesOnceAndItsReleaseAddsNothing() {
        let recorder = GestureEndRecorder()
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)

        session.cancel()
        XCTAssertEqual(recorder.settles, 1)
        XCTAssertNil(session.liveOverride)

        XCTAssertTrue(session.ended(), "the release after Esc still ends the gesture")
        XCTAssertEqual(recorder.settles, 1)
        XCTAssertTrue(recorder.commits.isEmpty)
    }

    @MainActor
    func testAbandoningALiveDragSettlesOnce() {
        let recorder = GestureEndRecorder()
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)

        session.abandon()

        XCTAssertEqual(recorder.settles, 1)
        XCTAssertFalse(session.ended(), "no release is owed after abandon")
        XCTAssertEqual(recorder.settles, 1)
    }

    @MainActor
    func testAReleaseWithNoGestureSettlesNothing() {
        let recorder = GestureEndRecorder()
        let session = makeSession(recorder)

        XCTAssertFalse(session.ended())

        XCTAssertEqual(recorder.settles, 0)
    }

    /// A newer drag owns the geometry now and settles at its own end.
    @MainActor
    func testACommitLandingAfterANewerDragBeganSettlesNothingForIt() async {
        let recorder = GestureEndRecorder()
        recorder.holdCommits = true
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)
        session.ended()
        let firstCommit = session.pendingCommit
        for _ in 0..<1_000 where recorder.commits.isEmpty {
            await Task.yield()
        }

        session.began(Self.divider)
        recorder.releaseCommit()
        await firstCommit?.value

        XCTAssertEqual(recorder.settles, 0)
        XCTAssertNotNil(session.liveOverride, "the newer drag's preview survives the older commit")

        session.ended()
        XCTAssertEqual(recorder.settles, 1)
    }
}
