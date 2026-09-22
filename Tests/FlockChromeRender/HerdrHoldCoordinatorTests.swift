import AppKit
import XCTest
@testable import FlockCore

/// Which AppKit edge hands flock's panes back to herdr.
///
/// The release is not cosmetic: it drops the pane's herdr control client, so
/// herdr stops streaming that pane's frames and the surface goes on showing
/// the last one it was sent. Tying that to activation meant a flock window the
/// user could still see froze 0.4s after any other app came forward, then
/// caught up in one burst when they clicked back -- panes that read as live
/// while they were minutes stale.
@MainActor
final class HerdrHoldCoordinatorTests: XCTestCase {
    /// The regression this file exists for: frontmost is not the same
    /// question as on screen.
    func testAnAppSwitchAwayFromAWindowStillOnScreenDecidesNothing() {
        let recorder = HoldRecorder()
        let center = NotificationCenter()
        let coordinator = makeCoordinator(recorder: recorder, center: center, onScreen: { true })
        defer { withExtendedLifetime(coordinator) {} }

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        waitOutTheReleaseDelay()

        XCTAssertEqual(recorder.releases, 0, "a visible flock stopped streaming because another app came forward")
        XCTAssertEqual(recorder.takes, 0, "every pane's FIFO took a take it did not need")
    }

    /// Leaving the screen for real still hands the panes back, which is what
    /// puts them under herdr's own sizing again.
    func testLeavingTheScreenReleasesOnceTheDelayIsUp() {
        let recorder = HoldRecorder()
        let center = NotificationCenter()
        let onScreen = VisibilityBox(value: true)
        let coordinator = makeCoordinator(recorder: recorder, center: center, onScreen: { onScreen.value })
        defer { withExtendedLifetime(coordinator) {} }

        onScreen.value = false
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        waitOutTheReleaseDelay()

        XCTAssertEqual(recorder.releases, 1)
    }

    /// And coming back takes them again, so the panes resume streaming.
    func testComingBackOnScreenTakesThePanesAgain() {
        let recorder = HoldRecorder()
        let center = NotificationCenter()
        let onScreen = VisibilityBox(value: true)
        let coordinator = makeCoordinator(recorder: recorder, center: center, onScreen: { onScreen.value })
        defer { withExtendedLifetime(coordinator) {} }

        onScreen.value = false
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        waitOutTheReleaseDelay()
        onScreen.value = true
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        waitOutTheReleaseDelay()

        XCTAssertEqual(recorder.releases, 1)
        XCTAssertEqual(recorder.takes, 1)
    }

    /// Activation asserts the take without consulting visibility. AppKit can
    /// still report no visible window at the instant the app comes forward,
    /// and a take withheld there would leave every pane released with no later
    /// edge to correct it.
    func testActivationTakesThePanesBackEvenWhileAppKitStillReportsNoVisibleWindow() {
        let recorder = HoldRecorder()
        let center = NotificationCenter()
        let onScreen = VisibilityBox(value: true)
        let coordinator = makeCoordinator(recorder: recorder, center: center, onScreen: { onScreen.value })
        defer { withExtendedLifetime(coordinator) {} }

        onScreen.value = false
        center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        waitOutTheReleaseDelay()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        waitOutTheReleaseDelay()

        XCTAssertEqual(recorder.takes, 1)
    }

    private func makeCoordinator(
        recorder: HoldRecorder, center: NotificationCenter, onScreen: @MainActor @escaping () -> Bool
    ) -> HerdrHoldCoordinator {
        HerdrHoldCoordinator(
            release: { recorder.releases += 1 },
            take: { recorder.takes += 1 },
            notificationCenter: center,
            isOnScreen: onScreen
        )
    }

    /// Spins the main run loop past the debounce, which is what the release
    /// timer is scheduled on. An expectation cannot stand in for it: the case
    /// that matters most asserts that NOTHING fired.
    private func waitOutTheReleaseDelay() {
        let idle = expectation(description: "the release delay elapsed")
        idle.isInverted = true
        wait(for: [idle], timeout: HoldPolicy.releaseDelay * 2 + 0.2)
    }
}

@MainActor
private final class HoldRecorder {
    var releases = 0
    var takes = 0
}

@MainActor
private final class VisibilityBox {
    var value: Bool

    init(value: Bool) {
        self.value = value
    }
}
