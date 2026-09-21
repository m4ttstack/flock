import XCTest
@testable import FlockCore

final class PaneLoaderPolicyTests: XCTestCase {
    private let shownAt = ContinuousClock.now

    /// The one place the floor's actual value is asserted, so a choreography
    /// change that moves it cannot pass unnoticed. Every other test below
    /// reads the constant.
    func testTheFloorWorksOutTo1000ms() {
        XCTAssertEqual(PaneLoaderPolicy.minimumDisplay, .milliseconds(1000))
    }

    /// Why that number: the dismissal cross-fade straddles the end of a trail
    /// loop, so the trail is at full spread in the middle of the fade rather
    /// than at the start of it. Beginning the fade at the loop's end instead
    /// leaves the echoes visibly gathering again underneath it.
    func testTheFadeIsCentredOnTheEndOfATrailLoop() {
        let floor = Double(PaneLoaderPolicy.minimumDisplay.components.seconds)
            + Double(PaneLoaderPolicy.minimumDisplay.components.attoseconds) / 1e18

        XCTAssertEqual(
            floor + PaneLoaderPolicy.dismissCrossFade / 2,
            PaneLoaderChoreography.loopDuration,
            accuracy: 0.0001
        )
    }

    func testFirstFrameBeforeMinimumHoldsToTheFloor() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(80))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, shownAt.advanced(by: PaneLoaderPolicy.minimumDisplay))
    }

    func testFirstFrameAfterMinimumDismissesImmediatelyWithNoAddedDelay() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(5000))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, firstFrameAt)
    }

    func testFirstFrameExactlyAtTheMinimumDismissesAtThatInstant() {
        let firstFrameAt = shownAt.advanced(by: PaneLoaderPolicy.minimumDisplay)

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt)

        XCTAssertEqual(dismissAt, firstFrameAt)
    }

    /// A fresh pane is a pristine launcher pane AND has no first frame, so
    /// both the loader and the launcher wanted to draw, and the buttons
    /// landed across the middle of the mark on every new tab.
    func testTheLauncherStandsDownWhileTheLoaderIsUp() {
        XCTAssertFalse(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: true, loaderVisible: true)
        )
    }

    func testTheLauncherShowsOnAPristinePaneOnceTheLoaderIsGone() {
        XCTAssertTrue(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: true, loaderVisible: false)
        )
    }

    func testAPaneThatIsNotPristineNeverShowsTheLauncher() {
        XCTAssertFalse(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: false, loaderVisible: false)
        )
        XCTAssertFalse(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: false, loaderVisible: true)
        )
    }

    func testACustomMinimumIsHonoredJustLikeTheDefault() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(10))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt, minimum: .milliseconds(500))

        XCTAssertEqual(dismissAt, shownAt.advanced(by: .milliseconds(500)))
    }
}
