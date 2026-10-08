import FlockCore
import XCTest
@testable import Flock

/// libghostty never announces a changed screen on macOS, so the row count is
/// polled; only a changed count may reach the launcher.
@MainActor
final class ScreenActivityTimerTests: XCTestCase {
    private func makeSession() throws -> GhosttySession {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        return host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors())
        )
    }

    func testAChangedCountIsReportedOnce() throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen = ["prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }

        session.tickScreenActivity()
        screen = ["prompt", "output"]
        session.tickScreenActivity()

        XCTAssertEqual(reports, [1, 2])
    }

    func testAnUnchangedCountIsSilent() throws {
        let session = try makeSession()
        var reports: [Int] = []
        session.screenRowsOverride = { ["prompt", "", "   "] }
        session.onScreenActivity = { reports.append($0) }

        session.tickScreenActivity()
        session.tickScreenActivity()
        session.tickScreenActivity()

        XCTAssertEqual(reports, [1], "blank and whitespace rows do not count, and a repeat says nothing")
    }

    func testAParkedSessionDoesNotReportUntilItIsUnparked() throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen = ["prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }
        session.tickScreenActivity()

        session.setParked(true)
        screen = ["prompt", "output"]
        session.tickScreenActivity()
        XCTAssertEqual(reports, [1], "a parked session reads nothing")

        session.setParked(false)
        XCTAssertEqual(reports, [1, 2], "unparking reads at once")
    }
}
