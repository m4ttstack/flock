import XCTest
@testable import FlockCore

final class MissionBoardTests: XCTestCase {
    /// 03:33:20 on 24 January 1970, in `utc`.
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private typealias W = MissionFixture.Workspace
    private typealias T = MissionFixture.Tab
    private typealias P = MissionFixture.Pane

    private func board(
        _ model: SessionModel, toasts: AttentionToastStack = AttentionToastStack(),
        changedAgo: [String: TimeInterval] = [:], board names: BoardWorkspaceNames? = nil, opensOlder: Bool = false,
        opensUnknown: Bool = false, unrecorded: Set<String> = []
    ) -> MissionBoard {
        MissionBoard(
            model: model, sections: RailSections(model: model, board: names), toasts: toasts,
            history: history(model, changedAgo: changedAgo, unrecorded: unrecorded), now: now, calendar: utc,
            opensOlder: opensOlder, opensUnknown: opensUnknown
        )
    }

    /// Every pane entered its current status two hours ago, or `changedAgo`
    /// seconds before now when listed. An `unrecorded` pane has no record, so
    /// its last change is unknown.
    private func history(
        _ model: SessionModel, changedAgo: [String: TimeInterval], unrecorded: Set<String> = []
    ) -> PaneStatusHistory {
        var seeds: [PaneID: PaneStatusHistory.Transition] = [:]
        for (id, pane) in model.panes where !unrecorded.contains(id.rawValue) {
            seeds[id] = .init(status: pane.agentStatus, at: now.addingTimeInterval(-(changedAgo[id.rawValue] ?? 7200)))
        }
        var history = PaneStatusHistory()
        history.observe(model, at: now, seeds: seeds)
        return history
    }

    private func restCards(_ board: MissionBoard) -> [String] {
        board.atRest.flatMap { $0.groups.flatMap(\.cards) }.map(\.paneID.rawValue)
    }

    private func toast(_ pane: String, _ kind: AttentionToast.Kind, raised: TimeInterval) -> AttentionToast {
        let parts = pane.split(separator: ":")
        return AttentionToast(
            paneID: PaneID(rawValue: pane), tabID: TabID(rawValue: "\(parts[0]):\(parts[1])"),
            workspaceID: WorkspaceID(rawValue: String(parts[0])), kind: kind, subject: "s", breadcrumb: "b",
            raisedAt: now.addingTimeInterval(-raised)
        )
    }

    func testAToastedPaneIsInNeedsYouOldestFirst() {
        let model = MissionFixture.single([.blocked, .done, .working])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 600))
        toasts.raise(toast("w1:t1:p2", .finished, raised: 60))
        let b = board(model, toasts: toasts)
        XCTAssertEqual(b.needsYou.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p1", "w1:t1:p2"])
        XCTAssertEqual(b.needsYou.first?.cards.first?.since, now.addingTimeInterval(-600))
        XCTAssertEqual(b.working.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p3"])
    }

    /// Blocked waits on the person until it is unblocked: clearing or opening
    /// its card leaves it in Needs you. A done pane's card is what keeps it.
    func testABlockedPaneStaysInNeedsYouWithoutACardButADoneOneRests() {
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p2", .needsInput, raised: 60))
        let b = board(
            MissionFixture.single([.blocked, .blocked, .done]), toasts: toasts,
            changedAgo: ["w1:t1:p1": 600, "w1:t1:p3": 120]
        )
        XCTAssertEqual(b.needsYou.top.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p1", "w1:t1:p2"], "oldest first")
        XCTAssertEqual(b.needsYou.bottomCount, 0)
        XCTAssertEqual(restCards(b), ["w1:t1:p3"])
    }

    func testAPaneQuietForWeeksIsStillAtRest() {
        let b = board(MissionFixture.single([.idle]), changedAgo: ["w1:t1:p1": 30 * 24 * 3600])
        XCTAssertEqual(b.atRest.map(\.age), [.older])
        XCTAssertEqual(restCards(b), ["w1:t1:p1"])
        XCTAssertEqual(b.columns[2].map(\.rawValue), ["w1:t1:p1"])
    }

    func testAWorkingPaneStaysInWorkingHoweverLongItWorks() {
        let b = board(MissionFixture.single([.working]), changedAgo: ["w1:t1:p1": 30 * 24 * 3600])
        XCTAssertEqual(b.working.flatMap(\.cards).count, 1)
        XCTAssertTrue(b.atRest.isEmpty)
    }

    func testAClaudePaneBusyInTheBackgroundIsInWorkingAndSaysWhy() {
        var model = MissionFixture.single([.idle, .done, .idle])
        for id in ["w1:t1:p1", "w1:t1:p2"] { model.panes[PaneID(rawValue: id)]?.agent = "claude" }
        let work = [PaneID(rawValue: "w1:t1:p1"): "1 shell", PaneID(rawValue: "w1:t1:p2"): "2 monitors"]
        let b = MissionBoard(
            model: model, sections: RailSections(model: model, board: nil), toasts: AttentionToastStack(),
            history: history(model, changedAgo: ["w1:t1:p1": 3 * 60, "w1:t1:p2": 60]), backgroundWork: work, now: now, calendar: utc
        )
        let working = b.working.flatMap(\.cards)
        XCTAssertEqual(working.map(\.paneID.rawValue), ["w1:t1:p1", "w1:t1:p2"])
        XCTAssertEqual(working.map(\.status), [.working, .working])
        XCTAssertEqual(working.map { $0.stateText(at: now) }, ["working · 1 shell · 3m", "working · 2 monitors · 1m"])
        XCTAssertEqual(restCards(b), ["w1:t1:p3"])
    }

    func testBackgroundWorkOnAPaneThatIsNotClaudeIsIgnored() {
        let model = MissionFixture.single([.idle])
        let b = MissionBoard(
            model: model, sections: RailSections(model: model, board: nil), toasts: AttentionToastStack(),
            history: history(model, changedAgo: [:]), backgroundWork: [PaneID(rawValue: "w1:t1:p1"): "1 shell"], now: now,
            calendar: utc
        )
        XCTAssertTrue(b.working.isEmpty)
        XCTAssertEqual(restCards(b), ["w1:t1:p1"])
    }

    func testAToastedPaneKeepsItsToastsStatusOverBackgroundWork() {
        var model = MissionFixture.single([.done])
        model.panes[PaneID(rawValue: "w1:t1:p1")]?.agent = "claude"
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .finished, raised: 60))
        let sections = RailSections(model: model, board: nil)
        let history = history(model, changedAgo: [:])
        let work = [PaneID(rawValue: "w1:t1:p1"): "1 shell"]
        let b = MissionBoard(model: model, sections: sections, toasts: toasts, history: history, backgroundWork: work, now: now)
        XCTAssertEqual(b.needsYou.flatMap(\.cards).map(\.status), [.done])
        XCTAssertTrue(b.working.isEmpty)
        let card = MissionBoard.card(
            PaneID(rawValue: "w1:t1:p1"), model: model, sections: sections, toasts: toasts, history: history, backgroundWork: work
        )
        XCTAssertEqual(card?.backgroundWork, nil)
        let untoasted = MissionBoard.card(
            PaneID(rawValue: "w1:t1:p1"), model: model, sections: sections, toasts: AttentionToastStack(), history: history,
            backgroundWork: work
        )
        XCTAssertEqual(untoasted?.shown, ShownStatus(.done, backgroundWork: "1 shell"))
        XCTAssertEqual(untoasted?.status, .working)
    }

    func testAtRestIsMostRecentChangeFirst() {
        let b = board(MissionFixture.single([.idle, .done]), changedAgo: ["w1:t1:p1": 600, "w1:t1:p2": 60])
        XCTAssertEqual(restCards(b), ["w1:t1:p2", "w1:t1:p1"])
    }

    func testRestAgeBoundaries() {
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
        }
        func age(_ since: Date?, now: Date) -> RestAge { RestAge.of(since, now: now, calendar: utc) }
        let afternoon = at(6, 15)
        XCTAssertEqual(age(afternoon.addingTimeInterval(-59 * 60), now: afternoon), .lastHour)
        XCTAssertEqual(age(afternoon.addingTimeInterval(-61 * 60), now: afternoon), .earlierToday)
        XCTAssertEqual(age(afternoon, now: afternoon), .lastHour)

        let pastMidnight = at(6, 0, 30)
        XCTAssertEqual(age(at(5, 23, 50), now: pastMidnight), .lastHour, "an hour reaches back across midnight")
        XCTAssertEqual(age(at(5, 23, 0), now: pastMidnight), .yesterday)
        XCTAssertEqual(age(at(6, 0), now: at(6, 2)), .earlierToday, "midnight is today")
        XCTAssertEqual(age(at(5, 23, 59, 59), now: at(6, 2)), .yesterday)

        XCTAssertEqual(age(at(5, 0), now: afternoon), .yesterday, "yesterday's first second")
        XCTAssertEqual(age(at(4, 23, 59, 59), now: afternoon), .thisWeek)

        XCTAssertEqual(age(afternoon.addingTimeInterval(-7 * 24 * 3600 + 1), now: afternoon), .thisWeek)
        XCTAssertEqual(age(afternoon.addingTimeInterval(-7 * 24 * 3600), now: afternoon), .older)
        XCTAssertEqual(age(nil, now: afternoon), .unknown, "no known change")
    }

    func testRestAgeReadsDaysInTheCalendarsTimeZone() {
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 3))!
        let since = now.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(RestAge.of(since, now: now, calendar: utc), .yesterday)
        XCTAssertEqual(RestAge.of(since, now: now, calendar: chicago), .earlierToday, "both are the evening of the 5th there")
    }

    func testAtRestSectionsRunMostRecentFirstAndAWorkspaceSplitsAcrossThem() {
        let model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "a", panes: [P(status: .idle), P(status: .idle), P(status: .done)])]),
            W(label: "flock", tabs: [T(label: "b", panes: [P(status: .idle), P(status: .done)])]),
        ])
        let b = board(model, changedAgo: [
            "w1:t1:p1": 30 * 60, "w2:t1:p1": 45 * 60,
            "w2:t1:p2": 4 * 3600, "w1:t1:p2": 5 * 3600,
            "w1:t1:p3": 3 * 24 * 3600,
        ])
        XCTAssertEqual(b.atRest.map(\.age), [.lastHour, .yesterday, .thisWeek], "an empty section is not drawn")
        XCTAssertEqual(b.atRest.map { $0.groups.map(\.name) }, [["acme", "flock"], ["flock", "acme"], ["acme"]])
        XCTAssertEqual(b.atRest.map { $0.groups.map { $0.cards.map(\.paneID.rawValue) } }, [
            [["w1:t1:p1"], ["w2:t1:p1"]], [["w2:t1:p2"], ["w1:t1:p2"]], [["w1:t1:p3"]],
        ])
        XCTAssertEqual(b.atRestCount, 5)
        XCTAssertEqual(b.columns[2].map(\.rawValue), restCards(b), "the keys walk the drawn order")
    }

    func testALongOlderSectionFoldsAndItsCardsLeaveTheKeys() {
        let model = MissionFixture.single(Array(repeating: .idle, count: 10))
        var changedAgo: [String: TimeInterval] = ["w1:t1:p1": 60]
        for pane in 2...10 { changedAgo["w1:t1:p\(pane)"] = 10 * 24 * 3600 + Double(pane) }
        let folded = board(model, changedAgo: changedAgo)
        let older = try! XCTUnwrap(folded.atRest.last)
        XCTAssertEqual(older.age, .older)
        XCTAssertEqual(older.count, 9)
        XCTAssertTrue(older.isCollapsible)
        XCTAssertTrue(older.isCollapsed)
        XCTAssertEqual(folded.columns[2].map(\.rawValue), ["w1:t1:p1"])
        XCTAssertEqual(folded.atRestCount, 10, "the lane still counts a folded section")
        XCTAssertNotNil(folded.card(PaneID(rawValue: "w1:t1:p5")), "a folded card is still found")

        let opened = board(model, changedAgo: changedAgo, opensOlder: true)
        XCTAssertFalse(opened.atRest.last!.isCollapsed)
        XCTAssertEqual(opened.columns[2].count, 10)
    }

    func testOlderFoldsOnlyPastEightPanes() {
        let model = MissionFixture.single(Array(repeating: .idle, count: 8))
        var changedAgo: [String: TimeInterval] = [:]
        for pane in 1...8 { changedAgo["w1:t1:p\(pane)"] = 10 * 24 * 3600 + Double(pane) }
        let b = board(model, changedAgo: changedAgo)
        XCTAssertFalse(b.atRest[0].isCollapsible)
        XCTAssertFalse(b.atRest[0].isCollapsed)
        XCTAssertEqual(b.columns[2].count, 8)
    }

    func testOnlyOlderEverFolds() {
        let model = MissionFixture.single(Array(repeating: .idle, count: 12))
        var changedAgo: [String: TimeInterval] = [:]
        for pane in 1...12 { changedAgo["w1:t1:p\(pane)"] = 3 * 24 * 3600 + Double(pane) }
        let b = board(model, changedAgo: changedAgo)
        XCTAssertEqual(b.atRest.map(\.age), [.thisWeek])
        XCTAssertFalse(b.atRest[0].isCollapsed)
    }

    func testAPaneWithNoKnownChangeRestsInUnknownAfterOlderInRailOrder() {
        let model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "a", panes: [P(status: .idle), P(status: .idle)])]),
            W(label: "flock", tabs: [T(label: "b", panes: [P(status: .idle), P(status: .done)])]),
        ])
        let b = board(
            model, changedAgo: ["w1:t1:p2": 30 * 24 * 3600, "w2:t1:p2": 60],
            unrecorded: ["w1:t1:p1", "w2:t1:p1"]
        )
        XCTAssertEqual(b.atRest.map(\.age), [.lastHour, .older, .unknown])
        let earlier = b.atRest[2]
        XCTAssertEqual(earlier.age.title, "Unknown")
        XCTAssertEqual(earlier.groups.map(\.name), ["acme", "flock"])
        XCTAssertEqual(earlier.groups.map { $0.cards.map(\.paneID.rawValue) }, [["w1:t1:p1"], ["w2:t1:p1"]])
        XCTAssertEqual(earlier.groups.flatMap(\.cards).map(\.since), [nil, nil])
        XCTAssertEqual(b.columns[2].map(\.rawValue), restCards(b), "the keys walk the drawn order")
        XCTAssertEqual(b.columns[2].last?.rawValue, "w2:t1:p1")
    }

    func testNoPaneIsInLastHourWhenNoChangeIsKnown() {
        let b = board(MissionFixture.single([.idle, .done]), unrecorded: ["w1:t1:p1", "w1:t1:p2"])
        XCTAssertEqual(b.atRest.map(\.age), [.unknown])
        XCTAssertEqual(restCards(b), ["w1:t1:p1", "w1:t1:p2"])
    }

    func testAPaneThatChangedAfterFirstSightLeavesUnknown() {
        let model = MissionFixture.single([.idle])
        var history = history(model, changedAgo: [:], unrecorded: ["w1:t1:p1"])
        let done = MissionFixture.single([.done])
        history.observe(done, at: now.addingTimeInterval(-300))
        let b = MissionBoard(
            model: done, sections: RailSections(model: done, board: nil), toasts: AttentionToastStack(),
            history: history, now: now, calendar: utc
        )
        XCTAssertEqual(b.atRest.map(\.age), [.lastHour])
    }

    func testUnknownFoldsOnlyPastEightPanesWithItsOwnOpenState() {
        let many = MissionFixture.single(Array(repeating: .idle, count: 9))
        let manyPanes = Set(many.panes.keys.map(\.rawValue))
        let folded = board(many, unrecorded: manyPanes)
        XCTAssertTrue(folded.atRest[0].isCollapsible)
        XCTAssertTrue(folded.atRest[0].isCollapsed)
        XCTAssertTrue(folded.columns[2].isEmpty)
        XCTAssertEqual(folded.atRestCount, 9)
        XCTAssertTrue(board(many, opensOlder: true, unrecorded: manyPanes).atRest[0].isCollapsed, "Older's flag does not open Unknown")
        let opened = board(many, opensUnknown: true, unrecorded: manyPanes)
        XCTAssertFalse(opened.atRest[0].isCollapsed)
        XCTAssertEqual(opened.columns[2].count, 9)

        let few = MissionFixture.single(Array(repeating: .idle, count: 8))
        let b = board(few, unrecorded: Set(few.panes.keys.map(\.rawValue)))
        XCTAssertFalse(b.atRest[0].isCollapsible)
        XCTAssertEqual(b.columns[2].count, 8)
    }

    func testNeedsYouGroupsByWorkspaceWithTheOldestCardOnTop() {
        let model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "a", panes: [P(status: .blocked), P(status: .done)])]),
            W(label: "flock", tabs: [T(label: "b", panes: [P(status: .blocked), P(status: .blocked)])]),
        ])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w2:t1:p1", .needsInput, raised: 900))
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 600))
        toasts.raise(toast("w2:t1:p2", .needsInput, raised: 300))
        toasts.raise(toast("w1:t1:p2", .finished, raised: 60))
        let b = board(model, toasts: toasts)
        XCTAssertEqual(b.needsYou.top.map(\.name), ["flock", "acme"], "the group holding the oldest card leads")
        XCTAssertEqual(b.needsYou.top.map { $0.cards.map(\.paneID.rawValue) }, [["w2:t1:p1", "w2:t1:p2"], ["w1:t1:p1"]])
        XCTAssertEqual(b.needsYou.bottom.map { $0.cards.map(\.paneID.rawValue) }, [["w1:t1:p2"]], "a finished card is under Done")
        XCTAssertEqual(b.columns[0].first?.rawValue, "w2:t1:p1", "the top card is the oldest blocked one")
        XCTAssertEqual(b.columns[0].map(\.rawValue), ["w2:t1:p1", "w2:t1:p2", "w1:t1:p1", "w1:t1:p2"], "the keys walk the drawn order")
    }

    func testNeedsYouDrawsBlockedAboveDoneEachOldestFirst() {
        let model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "a", panes: [P(status: .done), P(status: .blocked), P(status: .done)])]),
            W(label: "flock", tabs: [T(label: "b", panes: [P(status: .blocked)])]),
        ])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .finished, raised: 900))
        toasts.raise(toast("w2:t1:p1", .needsInput, raised: 600))
        toasts.raise(toast("w1:t1:p3", .finished, raised: 300))
        toasts.raise(toast("w1:t1:p2", .needsInput, raised: 60))
        let b = board(model, toasts: toasts)
        XCTAssertEqual(b.needsYou.top.map(\.name), ["flock", "acme"])
        XCTAssertEqual(b.needsYou.top.flatMap(\.cards).map(\.status), [.blocked, .blocked])
        XCTAssertEqual(b.needsYou.bottom.map(\.name), ["acme"], "a workspace can head a group in both")
        XCTAssertEqual(b.needsYou.bottom.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p1", "w1:t1:p3"])
        XCTAssertEqual([b.needsYou.topCount, b.needsYou.bottomCount, b.needsYou.cardCount], [2, 2, 4])
        XCTAssertEqual(
            b.columns[0].map(\.rawValue), ["w2:t1:p1", "w1:t1:p2", "w1:t1:p1", "w1:t1:p3"],
            "the keys walk Blocked, then Done"
        )
    }

    func testWorkingDrawsRealWorkAboveBackgroundWorkEachInRailOrder() {
        var model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "a", panes: [P(status: .idle), P(status: .working)])]),
            W(label: "flock", tabs: [T(label: "b", panes: [P(status: .working), P(status: .done)])]),
        ])
        for id in ["w1:t1:p1", "w2:t1:p2"] { model.panes[PaneID(rawValue: id)]?.agent = "claude" }
        let work = [PaneID(rawValue: "w1:t1:p1"): "1 shell", PaneID(rawValue: "w2:t1:p2"): "1 monitor"]
        let b = MissionBoard(
            model: model, sections: RailSections(model: model, board: nil), toasts: AttentionToastStack(),
            history: history(model, changedAgo: [:]), backgroundWork: work, now: now, calendar: utc
        )
        XCTAssertEqual(b.working.top.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p2", "w2:t1:p1"])
        XCTAssertEqual(b.working.bottom.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p1", "w2:t1:p2"])
        XCTAssertEqual(b.working.bottom.map(\.name), ["acme", "flock"])
        XCTAssertEqual(b.columns[1].map(\.rawValue), ["w1:t1:p2", "w2:t1:p1", "w1:t1:p1", "w2:t1:p2"])
    }

    func testASectionGroupsByWorkspaceMostRecentChangeFirst() {
        let model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "a", panes: [P(status: .idle), P(status: .done)])]),
            W(label: "flock", tabs: [T(label: "b", panes: [P(status: .idle), P(status: .idle)])]),
            W(label: "board", tabs: [T(label: "c", panes: [P(status: .done)])]),
        ])
        let b = board(model, changedAgo: [
            "w1:t1:p1": 900, "w1:t1:p2": 300,
            "w2:t1:p1": 60, "w2:t1:p2": 1200,
            "w3:t1:p1": 600,
        ])
        XCTAssertEqual(b.atRest.map(\.age), [.lastHour])
        XCTAssertEqual(b.atRest[0].groups.map(\.name), ["flock", "acme", "board"])
        XCTAssertEqual(b.atRest[0].groups.map { $0.cards.map(\.paneID.rawValue) }, [
            ["w2:t1:p1", "w2:t1:p2"], ["w1:t1:p2", "w1:t1:p1"], ["w3:t1:p1"],
        ])
        XCTAssertEqual(b.columns[2].map(\.rawValue), ["w2:t1:p1", "w2:t1:p2", "w1:t1:p2", "w1:t1:p1", "w3:t1:p1"], "the keys walk the drawn order")
    }

    func testWorkingFollowsRailOrderAndGroupsByWorkspace() {
        let names = BoardWorkspaceNames(reviews: "Reviews", responds: "Responses", doctors: "Doctors")
        let model = MissionFixture.model([
            W(label: "Responses", tabs: [T(label: "r", panes: [P(status: .working)])]),
            W(label: "repo-tools", tabs: [T(label: "a", panes: [P(status: .working)]), T(label: "b", panes: [P(status: .working)])]),
            W(label: "herd: auth-sweep", tabs: [T(label: "worker 1", panes: [P(status: .working)])]),
            W(label: "flock", tabs: [T(label: "c", panes: [P(status: .working)])]),
        ])
        let b = board(model, board: names)
        XCTAssertEqual(b.working.map(\.name), ["repo-tools", "flock", "Responses", "auth-sweep · herd 0/1"])
        XCTAssertEqual(b.working[0].cards.map(\.tabTitle), ["a", "b"])
    }

    func testCardsCarryTitleFolderAndTab() {
        let model = MissionFixture.model([W(label: "acme", tabs: [T(label: "api", panes: [P(status: .working, title: "Fix refunds", cwd: "/tmp/acme")])])])
        let card = board(model).working[0].cards[0]
        XCTAssertEqual(card.title, "Fix refunds")
        XCTAssertEqual(card.folder, "/tmp/acme")
        XCTAssertEqual(card.tabTitle, "api")
        XCTAssertEqual(card.workspaceName, "acme")
    }

    func testColumnsAreTheThreeDrawnLanesInOrder() {
        let model = MissionFixture.single([.blocked, .working, .idle])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 10))
        let b = board(model, toasts: toasts, changedAgo: ["w1:t1:p3": 60])
        XCTAssertEqual(b.columns.map { $0.map(\.rawValue) }, [["w1:t1:p1"], ["w1:t1:p2"], ["w1:t1:p3"]])
    }

    func testSelectionMovesWithinAndAcrossLanesSkippingEmptyOnes() {
        let a = PaneID(rawValue: "a"), b = PaneID(rawValue: "b"), c = PaneID(rawValue: "c"), d = PaneID(rawValue: "d")
        let columns = [[a, b], [], [c, d]]
        XCTAssertEqual(MissionSelection.move(a, .down, in: columns), b)
        XCTAssertEqual(MissionSelection.move(b, .down, in: columns), b)
        XCTAssertEqual(MissionSelection.move(b, .right, in: columns), d)
        XCTAssertEqual(MissionSelection.move(c, .left, in: columns), a)
        XCTAssertEqual(MissionSelection.move(nil, .down, in: columns), a)
        XCTAssertNil(MissionSelection.move(nil, .down, in: [[], [], []]))
    }

    func testASelectionNoCardHoldsFallsToTheFirstCardOrToNothing() {
        let a = PaneID(rawValue: "a"), b = PaneID(rawValue: "b"), gone = PaneID(rawValue: "gone")
        let columns = [[], [a], [b]]
        XCTAssertEqual(MissionSelection.resolve(b, in: columns), b)
        XCTAssertEqual(MissionSelection.resolve(gone, in: columns), a, "a folded or closed pane is not kept")
        XCTAssertEqual(MissionSelection.resolve(nil, in: columns), a)
        XCTAssertNil(MissionSelection.resolve(gone, in: [[], [], []]), "no drawn card, nothing to select or open")
    }

    func testCardFindsAPaneInWhicheverLaneHoldsIt() {
        let model = MissionFixture.single([.blocked, .working, .idle, .idle])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 600))
        let b = board(model, toasts: toasts, changedAgo: ["w1:t1:p3": 120])
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p1")), b.needsYou.first?.cards.first)
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p2")), b.working.first?.cards.first)
        XCTAssertEqual(b.atRest.map(\.age), [.lastHour, .earlierToday], "the premise")
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p3")), b.atRest[0].groups.first?.cards.first)
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p4")), b.atRest[1].groups.first?.cards.first)
        XCTAssertNil(b.card(PaneID(rawValue: "w9:t1:p1")))
    }

    func testOnePanesCardIsTheCardTheBoardDrawsForIt() {
        let model = MissionFixture.model([
            W(label: "acme", tabs: [T(label: "api", panes: [P(status: .blocked), P(status: .working), P(status: .idle), P(status: .idle)])]),
            W(label: "herd: auth-sweep", tabs: [T(label: "worker 1", panes: [P(status: .working)])]),
        ])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 600))
        let changedAgo = ["w1:t1:p3": 120.0]
        let sections = RailSections(model: model, board: nil)
        let b = board(model, toasts: toasts, changedAgo: changedAgo)
        let history = history(model, changedAgo: changedAgo)
        for pane in model.panes.keys {
            let card = MissionBoard.card(pane, model: model, sections: sections, toasts: toasts, history: history)
            XCTAssertNotNil(card, pane.rawValue)
            XCTAssertEqual(card, b.card(pane), pane.rawValue)
        }
        XCTAssertNil(MissionBoard.card(PaneID(rawValue: "w9:t1:p1"), model: model, sections: sections, toasts: toasts, history: history))
    }

    func testStateTextIsTheStatusAndHowLongItHasHeld() {
        let card = board(MissionFixture.single([.blocked]), changedAgo: ["w1:t1:p1": 12 * 60]).needsYou.top[0].cards[0]
        XCTAssertEqual(card.stateText(at: now), "blocked 12m")
        let unrecorded = MissionCard(
            paneID: card.paneID, workspaceID: card.workspaceID, tabID: card.tabID, workspaceName: "", tabTitle: "",
            title: "", status: .working, since: nil, folder: ""
        )
        XCTAssertEqual(unrecorded.stateText(at: now), "working")
        let unknown = board(MissionFixture.single([.idle]), unrecorded: ["w1:t1:p1"]).atRest[0].groups[0].cards[0]
        XCTAssertEqual(unknown.stateText(at: now), "idle", "no known change, no age")
    }

    func testAgeText() {
        XCTAssertEqual(MissionAge.text(20), "<1m")
        XCTAssertEqual(MissionAge.text(18 * 60), "18m")
        XCTAssertEqual(MissionAge.text(64 * 60), "1h 4m")
        XCTAssertEqual(MissionAge.text(3 * 3600), "3h")
    }

    func testMissionControlTakesBareArrowsAndReturnAndLeavesShortcutsAlone() {
        func decide(_ code: UInt16, command: Bool = false, shift: Bool = false) -> MissionKey.Decision {
            MissionKey.decide(keyCode: code, command: command, control: false, option: false, shift: shift)
        }
        XCTAssertEqual(decide(126), .move(.up))
        XCTAssertEqual(decide(125), .move(.down))
        XCTAssertEqual(decide(123), .move(.left))
        XCTAssertEqual(decide(124), .move(.right))
        XCTAssertEqual(decide(36), .open)
        XCTAssertEqual(decide(76), .open)
        XCTAssertEqual(decide(38), .pass, "J")
        XCTAssertEqual(decide(125, command: true), .pass)
        XCTAssertEqual(decide(125, shift: true), .pass)
        XCTAssertEqual(decide(53), .pass, "Esc closes the grid elsewhere")
    }

    func testARenameFieldKeepsArrowsAndReturn() {
        for code: UInt16 in [126, 125, 123, 124, 36, 76] {
            XCTAssertEqual(
                MissionKey.decide(keyCode: code, command: false, control: false, option: false, shift: false, editingText: true),
                .pass, "key \(code) belongs to the field"
            )
        }
    }

    func testTheGridYieldsEscapeToARenameField() {
        XCTAssertEqual(EscapeRoute.route(dragIdle: true, gridShown: true, gridYieldsEscape: true, railTakesEscape: false), .focusedView)
    }
}
