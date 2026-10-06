import XCTest
@testable import FlockCore

final class PaneStatusHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let pane = PaneID(rawValue: "w1:t1:p1")

    func testAPaneFirstSeenIsRecordedAsEnteringItsStatusThen() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        XCTAssertEqual(history.lastChange(of: pane), t0)
        XCTAssertEqual(history.age(of: pane, at: t0.addingTimeInterval(90)), 90)
    }

    func testAnUnchangedStatusAddsNothing() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([.working]), at: t0.addingTimeInterval(60))
        XCTAssertEqual(history.lastChange(of: pane), t0)
    }

    func testAChangeIsRecordedAtItsTime() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([.blocked]), at: t0.addingTimeInterval(300))
        XCTAssertEqual(history.lastChange(of: pane), t0.addingTimeInterval(300))
    }

    func testAPaneHerdrNoLongerReportsIsForgotten() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([]), at: t0.addingTimeInterval(1))
        XCTAssertNil(history.lastChange(of: pane))
    }

    func testTrimmingKeepsTheTransitionInForceAtTheWindowStart() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.idle]), at: t0)
        history.observe(MissionFixture.single([.working]), at: t0.addingTimeInterval(10))
        let later = t0.addingTimeInterval(2 * 3600)
        history.observe(MissionFixture.single([.working]), at: later)
        XCTAssertEqual(history.lastChange(of: pane), t0.addingTimeInterval(10))
        XCTAssertEqual(history.segments(of: pane, at: later).map(\.status), [.working])
        XCTAssertEqual(
            history.transitions[pane],
            [PaneStatusHistory.Transition(status: .working, at: t0.addingTimeInterval(10))]
        )
    }

    func testTrimmingKeepsEntriesNewerThanTheWindowStart() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.idle]), at: t0)
        history.observe(MissionFixture.single([.working]), at: t0.addingTimeInterval(10))
        let later = t0.addingTimeInterval(2 * 3600)
        let recent = later.addingTimeInterval(-600)
        history.observe(MissionFixture.single([.blocked]), at: recent)
        history.observe(MissionFixture.single([.blocked]), at: later)
        XCTAssertEqual(history.transitions[pane]?.map(\.status), [.working, .blocked])
        XCTAssertEqual(history.transitions[pane]?.last?.at, recent)
    }

    func testSegmentsCoverTheLastHourWithTheUnrecordedStartLeftEmpty() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: t0)
        history.observe(MissionFixture.single([.blocked]), at: t0.addingTimeInterval(15 * 60))
        let now = t0.addingTimeInterval(20 * 60)
        let segments = history.segments(of: pane, at: now)
        XCTAssertEqual(segments.map(\.status), [nil, .working, .blocked])
        XCTAssertEqual(segments.map { $0.end.timeIntervalSince($0.start) }, [40 * 60, 15 * 60, 5 * 60])
    }

    func testAPaneNeverSeenIsOneEmptySegment() {
        let history = PaneStatusHistory()
        XCTAssertEqual(history.segments(of: pane, at: t0).map(\.status), [nil])
    }
}
