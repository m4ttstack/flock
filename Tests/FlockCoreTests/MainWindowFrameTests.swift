import CoreGraphics
import XCTest
@testable import FlockCore

/// The window opens where it was left, but only where that is still a place:
/// a frame saved against a display that has since been unplugged is not
/// honoured, and a frame that has drifted off the edge of the screen it does
/// land on is pulled back far enough to be grabbed by its title bar.
final class MainWindowFrameTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1000)

    // MARK: - Nothing to honour

    func testAnAppWithNothingSavedTakesTheWindowAsItComes() {
        XCTAssertNil(MainWindowFrame.restored(from: nil, visibleScreenFrames: [screen]))
    }

    func testAStringThatDoesNotReadBackAsAFrameIsIgnored() {
        XCTAssertNil(MainWindowFrame.restored(from: "", visibleScreenFrames: [screen]))
        XCTAssertNil(MainWindowFrame.restored(from: "not a frame", visibleScreenFrames: [screen]))
    }

    func testAFrameWithNoAreaIsIgnored() {
        XCTAssertNil(
            MainWindowFrame.restored(from: "{{100, 100}, {0, 600}}", visibleScreenFrames: [screen])
        )
        XCTAssertNil(
            MainWindowFrame.restored(from: "{{100, 100}, {-800, -600}}", visibleScreenFrames: [screen])
        )
    }

    /// The unplugged-display case. The frame is perfectly readable; there is
    /// simply nowhere left that it describes.
    func testAFrameNoAttachedScreenOverlapsIsNotRestored() {
        let offDisplay = MainWindowFrame.encoded(CGRect(x: 3000, y: 100, width: 800, height: 600))

        XCTAssertNil(MainWindowFrame.restored(from: offDisplay, visibleScreenFrames: [screen]))
    }

    func testAFrameIsNotRestoredWhenNoScreenIsAttachedAtAll() {
        let saved = MainWindowFrame.encoded(CGRect(x: 100, y: 100, width: 800, height: 600))

        XCTAssertNil(MainWindowFrame.restored(from: saved, visibleScreenFrames: []))
    }

    /// Touching along an edge is not overlapping: the window would be entirely
    /// beside the screen, not on it.
    func testAFrameThatOnlyTouchesAScreensEdgeIsNotRestored() {
        let beside = MainWindowFrame.encoded(CGRect(x: 1920, y: 100, width: 800, height: 600))

        XCTAssertNil(MainWindowFrame.restored(from: beside, visibleScreenFrames: [screen]))
    }

    // MARK: - The frame that still fits

    func testAFrameStillOnItsScreenComesBackExactly() {
        let frame = CGRect(x: 240, y: 180, width: 1100, height: 700)

        XCTAssertEqual(
            MainWindowFrame.restored(from: MainWindowFrame.encoded(frame), visibleScreenFrames: [screen]),
            frame
        )
    }

    func testAFrameSurvivesBeingWrittenDownAndReadBack() {
        let frame = CGRect(x: 12.5, y: 34.5, width: 1000.5, height: 640.5)

        XCTAssertEqual(
            MainWindowFrame.restored(from: MainWindowFrame.encoded(frame), visibleScreenFrames: [screen]),
            frame
        )
    }

    // MARK: - The frame the screen has to argue with

    func testAWindowLargerThanItsScreenIsCutDownToIt() {
        XCTAssertEqual(
            MainWindowFrame.constrained(CGRect(x: 0, y: 0, width: 3000, height: 2000), to: screen),
            screen
        )
    }

    /// AppKit itself never lets a window be dragged above the menu bar, so a
    /// frame whose top edge is over the screen's can only have come from a
    /// display that is no longer there.
    func testATopEdgeAboveTheScreenIsPushedDownToIt() {
        let constrained = MainWindowFrame.constrained(
            CGRect(x: 100, y: 600, width: 800, height: 600), to: screen
        )

        XCTAssertEqual(constrained, CGRect(x: 100, y: 400, width: 800, height: 600))
    }

    func testAFrameHangingBelowTheScreenIsPushedUpOntoIt() {
        let constrained = MainWindowFrame.constrained(
            CGRect(x: 100, y: -300, width: 800, height: 600), to: screen
        )

        XCTAssertEqual(constrained, CGRect(x: 100, y: 0, width: 800, height: 600))
    }

    // MARK: - Enough of the title bar to grab

    func testAWindowPushedOffTheRightKeepsAGrabbableSliceOnScreen() {
        let constrained = MainWindowFrame.constrained(
            CGRect(x: 1900, y: 100, width: 800, height: 600), to: screen
        )

        XCTAssertEqual(constrained.minX, screen.maxX - MainWindowFrame.grabbableWidth)
        XCTAssertEqual(constrained.size, CGSize(width: 800, height: 600))
    }

    func testAWindowPushedOffTheLeftKeepsAGrabbableSliceOnScreen() {
        let constrained = MainWindowFrame.constrained(
            CGRect(x: -780, y: 100, width: 800, height: 600), to: screen
        )

        XCTAssertEqual(constrained.maxX, screen.minX + MainWindowFrame.grabbableWidth)
    }

    /// A window narrower than the grabbable slice cannot give up part of
    /// itself, so all of it stays on the screen.
    func testAWindowNarrowerThanTheSliceIsKeptWhollyOnScreen() {
        let constrained = MainWindowFrame.constrained(
            CGRect(x: 1900, y: 100, width: 60, height: 600), to: screen
        )

        XCTAssertEqual(constrained.maxX, screen.maxX)
        XCTAssertEqual(constrained.minX, screen.maxX - 60)
    }

    /// A window sitting comfortably inside its screen is not moved by the
    /// grabbable rule at all.
    func testAWindowWellInsideItsScreenIsLeftWhereItIs() {
        let frame = CGRect(x: 300, y: 200, width: 900, height: 600)

        XCTAssertEqual(MainWindowFrame.constrained(frame, to: screen), frame)
    }

    // MARK: - Two screens

    /// A window straddling a boundary belongs to the display it covers most
    /// of, and it is that display's bounds it then answers to.
    func testAStraddlingWindowIsConstrainedByTheScreenItIsMostlyOn() {
        let right = CGRect(x: 1920, y: 200, width: 1920, height: 600)
        let saved = MainWindowFrame.encoded(CGRect(x: 1800, y: 100, width: 800, height: 600))

        XCTAssertEqual(
            MainWindowFrame.restored(from: saved, visibleScreenFrames: [screen, right]),
            CGRect(x: 1800, y: 200, width: 800, height: 600)
        )
    }

    func testTheOrderScreensAreListedInDoesNotChooseTheScreen() {
        let right = CGRect(x: 1920, y: 200, width: 1920, height: 600)
        let saved = MainWindowFrame.encoded(CGRect(x: 1800, y: 100, width: 800, height: 600))

        XCTAssertEqual(
            MainWindowFrame.restored(from: saved, visibleScreenFrames: [right, screen]),
            MainWindowFrame.restored(from: saved, visibleScreenFrames: [screen, right])
        )
    }

    // MARK: - The key

    /// Persisted under a fixed literal, so it is spelled out here too: a
    /// rename on one side only loses every frame already saved.
    func testTheFrameIsSavedUnderItsPublishedKey() {
        XCTAssertEqual(MainWindowFrame.defaultsKey, "flock.mainWindowFrame")
    }
}
