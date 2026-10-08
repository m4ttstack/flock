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

    func testABlankScreenIsNotReportedBeforeTheFirstRealCount() throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen: [String] = []
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }

        session.tickScreenActivity()
        screen = ["", "  "]
        session.tickScreenActivity()
        XCTAssertEqual(reports, [], "a surface that has not painted yet says nothing")

        screen = ["prompt"]
        session.tickScreenActivity()
        XCTAssertEqual(reports, [1])
    }

    /// An alt-screen switch can be read before the program's first paint.
    func testABlankReadBetweenPaintsIsSilent() throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen = ["prompt", "prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }

        session.tickScreenActivity()
        screen = []
        session.tickScreenActivity()
        screen = Array(repeating: "row", count: 40)
        session.tickScreenActivity()

        XCTAssertEqual(reports, [2, 40])
    }

    /// An open menu or a live window resize runs the main run loop in
    /// event-tracking mode; the count must keep moving through it.
    func testTheTimerFiresWhileTheRunLoopTracksEvents() throws {
        // A running NSApplication makes event tracking a common mode; this
        // test host never runs one, so it does the same itself.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let session = try makeSession()
        var reports: [Int] = []
        session.screenRowsOverride = { ["prompt"] }
        session.onScreenActivity = { reports.append($0) }

        // `run(mode:before:)` can return after any one source fires, so it
        // is driven until the deadline.
        let deadline = Date().addingTimeInterval(GhosttySession.screenActivityInterval * 2.5)
        while reports.isEmpty, Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
        }

        XCTAssertEqual(reports, [1], "the poll stalled outside the default run loop mode")
    }

    /// A pane's appearance unparks it twice; only a real transition reads.
    func testUnparkingAnUnparkedSessionReadsNothing() throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen = ["prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }
        session.tickScreenActivity()

        screen = ["prompt", "output"]
        session.setParked(false)
        session.setParked(false)

        XCTAssertEqual(reports, [1])
    }

    func testAStoppedSessionStaysSilentAfterUnparking() throws {
        let session = try makeSession()
        var reports: [Int] = []
        var screen = ["prompt"]
        session.screenRowsOverride = { screen }
        session.onScreenActivity = { reports.append($0) }
        session.tickScreenActivity()

        session.stopScreenActivity()
        session.setParked(false)
        screen = ["prompt", "output"]
        session.tickScreenActivity()

        XCTAssertEqual(reports, [1])
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
