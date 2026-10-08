import FlockCore
import XCTest
@testable import Flock

/// The row count is a full active-screen scan, so renders are throttled; the
/// last render of a burst still has to be seen, because an unfocused pane
/// never renders again on its own.
@MainActor
final class ScreenActivityThrottleTests: XCTestCase {
    private func makeSession() throws -> GhosttySession {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        return host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors())
        )
    }

    /// Three renders in 200ms: the first reports at once, the screen grows
    /// under the next two, and the growth is reported exactly once, by the
    /// trailing check, after the interval.
    func testARenderInsideTheIntervalIsReportedOnceAtTheIntervalsEnd() async throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen = ["prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }
        let start = Date()

        session.noteRenderForScreenActivity(now: start)
        screen = ["prompt", "output"]
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(0.1))
        screen = ["prompt", "output", "more"]
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(0.2))
        XCTAssertEqual(reports, [1], "renders inside the interval wait for the trailing check")

        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(reports, [1, 3], "the trailing check reports the screen as it is at the interval's end, once")
    }

    /// The cursor blinks: the same screen again is not a report.
    func testAnUnchangedScreenIsNotReportedAgain() throws {
        let session = try makeSession()
        var reports: [Int] = []
        session.screenRowsOverride = { ["prompt", "", "   "] }
        session.onScreenActivity = { reports.append($0) }
        let start = Date()

        session.noteRenderForScreenActivity(now: start)
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(0.6))
        session.noteRenderForScreenActivity(now: start.addingTimeInterval(1.2))

        XCTAssertEqual(reports, [1], "blank and whitespace rows do not count, and a repeat says nothing")
    }
}
