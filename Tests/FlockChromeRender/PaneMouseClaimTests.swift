import XCTest
@testable import FlockCore

/// A pane's program claiming the mouse is what tells the rt modal it has
/// drawn. The claim latches: an `rt run` picker hands its pane to the script
/// it picked, and the mouse going off then must not bring the loader back.
@MainActor
final class PaneMouseClaimTests: XCTestCase {
    func testTheSurfaceHandleReportsAClaimAndKeepsIt() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors())
        )
        let handle = GhosttySessionSurfaceHandle(session: session)
        XCTAssertFalse(handle.hasClaimedMouse, "a fresh pane's shell never claimed the mouse")

        session.setMouseCapture(enabled: true)
        XCTAssertTrue(handle.hasClaimedMouse)

        session.setMouseCapture(enabled: false)
        XCTAssertTrue(handle.hasClaimedMouse, "the claim is a latch, so a program handing off does not undo it")
    }

    /// The pane legend's mouse badge follows the program both ways, unlike
    /// the claim.
    func testTheSurfaceHandleReportsWhetherTheProgramHasTheMouseNow() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors())
        )
        let handle = GhosttySessionSurfaceHandle(session: session)
        XCTAssertFalse(handle.programHasMouse)

        session.setMouseCapture(enabled: true)
        XCTAssertTrue(handle.programHasMouse)

        session.setMouseCapture(enabled: false)
        XCTAssertFalse(handle.programHasMouse)
    }
}
