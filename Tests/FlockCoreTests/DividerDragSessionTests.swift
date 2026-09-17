import XCTest
import CoreGraphics
@testable import FlockCore

/// Records the ratios a `DividerDragSession` commits. `commit` can be held
/// open so a test can look between a release and its commit landing.
@MainActor
private final class CommitRecorder {
    private(set) var commits: [Double] = []
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
    private func makeSession(_ recorder: CommitRecorder) -> DividerDragSession {
        DividerDragSession(commit: { _, _, ratio in await recorder.commit(ratio) })
    }

    @MainActor
    func testAReleaseAfterARealMoveCommitsOnceAndHoldsThePreviewUntilItLands() async {
        let recorder = CommitRecorder()
        recorder.holdCommits = true
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)

        XCTAssertTrue(session.ended())
        for _ in 0..<1_000 where recorder.commits.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertNotNil(session.liveOverride, "the preview holds until the commit lands")

        recorder.releaseCommit()
        await session.pendingCommit?.value

        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertNil(session.liveOverride)
    }

    @MainActor
    func testAReleaseWithNoMoveCommitsNothing() {
        let recorder = CommitRecorder()
        let session = makeSession(recorder)
        session.began(Self.divider)

        XCTAssertTrue(session.ended())

        XCTAssertTrue(recorder.commits.isEmpty)
        XCTAssertNil(session.liveOverride)
    }

    @MainActor
    func testEscCommitsNothingAndItsReleaseStillEndsTheGesture() {
        let recorder = CommitRecorder()
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)

        session.cancel()
        XCTAssertNil(session.liveOverride)

        XCTAssertTrue(session.ended(), "the release after Esc still ends the gesture")
        XCTAssertTrue(recorder.commits.isEmpty)
    }

    @MainActor
    func testAbandoningALiveDragCommitsNothingAndOwesNoRelease() {
        let recorder = CommitRecorder()
        let session = makeSession(recorder)
        session.began(Self.divider)
        session.moved(to: Self.movedPointer, for: Self.divider)

        session.abandon()

        XCTAssertNil(session.liveOverride)
        XCTAssertFalse(session.ended(), "no release is owed after abandon")
        XCTAssertTrue(recorder.commits.isEmpty)
    }

    @MainActor
    func testAReleaseWithNoGestureEndsNothing() {
        let recorder = CommitRecorder()
        let session = makeSession(recorder)

        XCTAssertFalse(session.ended())

        XCTAssertTrue(recorder.commits.isEmpty)
    }

    /// A newer drag owns the geometry now: the older commit landing must not
    /// clear its preview.
    @MainActor
    func testACommitLandingAfterANewerDragBeganKeepsTheNewerPreview() async {
        let recorder = CommitRecorder()
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

        XCTAssertNotNil(session.liveOverride, "the newer drag's preview survives the older commit")
    }
}
