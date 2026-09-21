import AppKit
import XCTest
@testable import FlockCore

/// Plugging in or unplugging an external display changes the backing scale
/// factor some windows draw at, and libghostty has to be told
/// (`ghostty_surface_set_content_scale`) or it keeps rendering glyphs at the
/// old size -- too small on a display that gained scale, too big on one that
/// lost it. Two paths keep that in sync: a surface's own window mount
/// (`GhosttySurfaceView.viewDidMoveToWindow` -> `GhosttySession.attach`), and
/// the app-wide refresh (`GhosttyHost.refreshContentScaleForLiveSessions`)
/// that reaches surfaces sitting warm with no window at all when the
/// notification fires.
///
/// A real second display cannot be attached in a test run, so
/// `ScaleStubWindow` overrides `backingScaleFactor` directly -- the same
/// value `GhosttySession`'s own scale lookup reads from a real window.
@MainActor
final class ContentScaleRefreshTests: XCTestCase {
    private static let colors = GhosttyThemeColors(
        background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
        foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
        ansi: Array(repeating: GhosttyThemeColor(red: 128, green: 128, blue: 128), count: 16)
    )

    /// Covers hole 2 of the display-scale bug: a cached surface's view is
    /// re-parented into a different window (the warm-cache re-mount) rather
    /// than being recreated, and the remount alone must push the new scale.
    func testMountingIntoWindowWithDifferentBackingScaleRefreshesContentScale() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        let view = GhosttySurfaceView(session: session)
        let lowScale = ScaleStubWindow(scale: 1.0)
        let highScale = ScaleStubWindow(scale: 3.0)

        lowScale.contentView?.addSubview(view)
        let atLowScale = try XCTUnwrap(session.surfaceGeometry(), "surface never reported a grid at creation scale")

        highScale.contentView?.addSubview(view)
        let atHighScale = try XCTUnwrap(session.surfaceGeometry(), "surface never reported a grid after remount")

        XCTAssertNotEqual(
            atLowScale.cellPixels.width, atHighScale.cellPixels.width,
            "remounting into a window at a different backing scale must repaint at that scale, not the mount-time one"
        )
        XCTAssertGreaterThan(
            atHighScale.cellPixels.width, atLowScale.cellPixels.width,
            "3x should render wider cells in pixels than 1x, not merely different ones"
        )
    }

    /// Covers hole 1: the app-wide refresh has to reach every live session,
    /// including one whose pane is not the window that actually changed
    /// screens -- and hole 3's guard, in the same pass: a session whose view
    /// has no window right now must be left alone rather than stamped with
    /// whatever `NSScreen.main` happens to be, which is only right by
    /// coincidence for a surface about to be mounted somewhere else.
    func testRefreshContentScaleForLiveSessionsReachesMountedSessionsAndSkipsDetachedOnes() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")

        let mountedSession = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        let mountedView = GhosttySurfaceView(session: mountedSession)
        let window = ScaleStubWindow(scale: 1.0)
        window.contentView?.addSubview(mountedView)
        let mountedBefore = try XCTUnwrap(mountedSession.surfaceGeometry())

        let detachedSession = host.makeSession(
            paneID: PaneID(rawValue: "w1:p2"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        let detachedView = GhosttySurfaceView(session: detachedSession)
        // Built a real surface once, the same way a pane does before its tab
        // is ever switched away from, then parked: removed from its window
        // (as flock's warm cache leaves it) but still referenced, so its
        // surface is still alive with `view != nil` and `view.window == nil`.
        window.contentView?.addSubview(detachedView)
        detachedView.removeFromSuperview()
        XCTAssertNil(detachedView.window, "the parked view must have no window for this test to mean anything")
        let detachedBefore = try XCTUnwrap(detachedSession.surfaceGeometry())

        // The stand-in for a real monitor plug/unplug: the mounted pane's
        // window now reports a different scale, the way a real window does
        // once the display driving it changes.
        window.scaleOverride = 3.0
        host.refreshContentScaleForLiveSessions()

        let mountedAfter = try XCTUnwrap(mountedSession.surfaceGeometry())
        XCTAssertNotEqual(
            mountedBefore.cellPixels.width, mountedAfter.cellPixels.width,
            "the refresh-all path must reach a mounted session even though nothing asked its view directly"
        )

        let detachedAfter = try XCTUnwrap(detachedSession.surfaceGeometry())
        XCTAssertEqual(
            detachedBefore.cellPixels.width, detachedAfter.cellPixels.width,
            "a session with no window must be left alone, not guessed at from NSScreen.main"
        )
    }

    /// A display notification can arrive before the window's backing scale
    /// actually updates, so the event paths alone can leave a surface stale
    /// until restart. `GhosttySurfaceView.layout()` is called on every layout
    /// pass regardless of which, if any, notification fired, so it is where
    /// a stale scale gets a second chance to correct itself. This test never
    /// delivers a notification at all: only the window's scale changes,
    /// then a layout pass, proving the self-heal path works without one.
    func testLayoutPassSelfHealsStaleContentScaleWithoutNotification() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        let view = GhosttySurfaceView(session: session)
        let window = ScaleStubWindow(scale: 1.0)
        window.contentView?.addSubview(view)
        let before = try XCTUnwrap(session.surfaceGeometry(), "surface never reported a grid at creation scale")

        window.scaleOverride = 3.0
        view.layout()

        let after = try XCTUnwrap(session.surfaceGeometry(), "surface never reported a grid after layout")
        XCTAssertGreaterThan(
            after.cellPixels.width, before.cellPixels.width,
            "a layout pass alone must correct the surface's content scale, with no notification delivered"
        )
    }

    /// `layout()` runs on every pass, so reasserting the same scale on every
    /// one of them would issue a redundant surface command each time. Proves
    /// the guard belongs in `updateContentScale()` itself.
    func testLayoutPassWithUnchangedScaleAppliesNoRedundantSurfaceCommand() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        let view = GhosttySurfaceView(session: session)
        let window = ScaleStubWindow(scale: 1.0)
        window.contentView?.addSubview(view)
        let settledCount = session.contentScaleApplyCount

        view.layout()
        view.layout()

        XCTAssertEqual(
            session.contentScaleApplyCount, settledCount,
            "an unchanged scale must not issue a redundant ghostty_surface_set_content_scale call"
        )
    }
}

/// Overrides `backingScaleFactor` because no test run can plug in a second
/// real display -- this is the one property `GhosttySession`'s own scale
/// lookup reads from a live window, so overriding it here reproduces a
/// scale mismatch on any machine.
private final class ScaleStubWindow: NSWindow {
    var scaleOverride: CGFloat

    init(scale: CGFloat) {
        self.scaleOverride = scale
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        isReleasedWhenClosed = false
        contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    override var backingScaleFactor: CGFloat { scaleOverride }
}
