import XCTest
@testable import FlockCore

final class PaneLoaderPolicyTests: XCTestCase {
    private let shownAt = ContinuousClock.now

    /// The two numbers that decide whether the badge is felt at all, asserted
    /// here so moving either is a deliberate edit. Everything below reads the
    /// constants rather than repeating them.
    func testTheTwoTimersAreTheOnesChosen() {
        XCTAssertEqual(PaneLoaderPolicy.appearDelay, .milliseconds(200))
        XCTAssertEqual(PaneLoaderPolicy.minimumDisplay, .milliseconds(400))
    }

    /// The point of the whole feature: a pane that paints quickly says
    /// nothing. Every attach announcing itself, including the ones already
    /// finished, is what made the loader feel like a toll booth.
    func testAPaneThatPaintsInsideTheDelayNeverShowsTheBadge() {
        XCTAssertFalse(PaneLoaderPolicy.showsBadge(hasFirstFrame: false, elapsed: .milliseconds(80)))
        XCTAssertFalse(PaneLoaderPolicy.showsBadge(hasFirstFrame: true, elapsed: .milliseconds(80)))
    }

    func testAPaneStillWaitingPastTheDelayShowsTheBadge() {
        XCTAssertTrue(PaneLoaderPolicy.showsBadge(hasFirstFrame: false, elapsed: .milliseconds(201)))
        XCTAssertTrue(PaneLoaderPolicy.showsBadge(hasFirstFrame: false, elapsed: PaneLoaderPolicy.appearDelay))
    }

    /// A frame that lands after the delay has passed means the badge already
    /// appeared; the floor, not this, is what decides when it leaves.
    func testAFrameArrivingLateDoesNotRetractTheBadge() {
        XCTAssertFalse(PaneLoaderPolicy.showsBadge(hasFirstFrame: true, elapsed: .seconds(3)))
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

    /// The regression that put a frame of live terminal on screen before the
    /// badge dropped in front of it: a cold pane's first render runs before
    /// the cell has decided anything, so "no badge yet" is not "no badge
    /// coming", and libghostty has usually painted real content by then.
    func testAnUndecidedPaneHidesTheTerminalRatherThanFlashingIt() {
        XCTAssertFalse(
            PaneLoaderPolicy.showsTerminalSurface(hasFirstFrame: false, badgeVisible: false)
        )
    }

    /// The other half: revealing on the frame alone puts live content under a
    /// badge that is still holding its floor.
    func testTheTerminalStaysHiddenWhileTheBadgeHoldsItsFloor() {
        XCTAssertFalse(
            PaneLoaderPolicy.showsTerminalSurface(hasFirstFrame: true, badgeVisible: true)
        )
    }

    func testTheTerminalShowsOnceItHasAFrameAndTheBadgeIsGone() {
        XCTAssertTrue(
            PaneLoaderPolicy.showsTerminalSurface(hasFirstFrame: true, badgeVisible: false)
        )
    }

    /// A pane that has not painted has no shell ready to be typed into, and
    /// the launcher's buttons work by sending the harness name as input.
    func testTheLauncherWaitsForTheBadgeToGo() {
        XCTAssertFalse(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: true, badgeVisible: true)
        )
    }

    func testTheLauncherShowsOnAPristinePaneOnceTheBadgeIsGone() {
        XCTAssertTrue(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: true, badgeVisible: false)
        )
    }

    func testAPaneThatIsNotPristineNeverShowsTheLauncher() {
        XCTAssertFalse(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: false, badgeVisible: false)
        )
        XCTAssertFalse(
            PaneLoaderPolicy.showsLauncherOverlay(isPristineLauncherPane: false, badgeVisible: true)
        )
    }

    /// The card's hint read as a broken pane when it was really a pane still
    /// being built, so an app that can attach never shows it.
    func testAPaneStillWaitingOnItsSurfaceNeverShowsTheCard() {
        XCTAssertFalse(PaneLoaderPolicy.showsStatusCard(hasSurface: false, attachesSurfaces: true))
    }

    func testAnAppThatCannotAttachShowsTheCard() {
        XCTAssertTrue(PaneLoaderPolicy.showsStatusCard(hasSurface: false, attachesSurfaces: false))
    }

    func testAPaneWithASurfaceNeverShowsTheCard() {
        XCTAssertFalse(PaneLoaderPolicy.showsStatusCard(hasSurface: true, attachesSurfaces: true))
    }

    func testACustomMinimumIsHonoredJustLikeTheDefault() {
        let firstFrameAt = shownAt.advanced(by: .milliseconds(10))

        let dismissAt = PaneLoaderPolicy.dismissAt(shownAt: shownAt, firstFrameAt: firstFrameAt, minimum: .milliseconds(500))

        XCTAssertEqual(dismissAt, shownAt.advanced(by: .milliseconds(500)))
    }
}
