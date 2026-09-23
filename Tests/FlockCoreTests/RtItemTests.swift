import XCTest
@testable import FlockCore

final class RtItemTests: XCTestCase {
    private func item(kind: RtKind = .run, title: String = "pnpm run test", running: Bool = true, strip: RtStrip? = nil) -> RtItem {
        RtItem(
            id: "tok1", kind: kind, linked: TerminalID(rawValue: "term_a1"), workspaceID: WorkspaceID(rawValue: "wF"),
            tabIDs: [TabID(rawValue: "wF:t1")], firstPaneID: PaneID(rawValue: "wF:p1"),
            title: title, folder: "/Users/acme/src/app", isRunning: running, strip: strip
        )
    }

    func testTheButtonRestsWithNothingRunningAndCountsWhatIs() {
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: false, runningItems: 3, hasRunner: true), .absent)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 0, hasRunner: false), .rest)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: false), .active(count: 2))
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: true), .active(count: 3))
    }

    func testTheMenuOffersTheCommandsThenThePanesItems() {
        let rows = RtMenuModel.rows(hasRunner: false, runItems: [item(), item(title: "pnpm run build", running: false, strip: .finished(0))])
        XCTAssertEqual(rows.map(\.title), [
            "nav · browse files here", "glitter · git status", "run · run a script…", "runner",
            "pnpm run test · running", "pnpm run build · finished",
        ])
        XCTAssertEqual(rows.map(\.startsSection), [false, false, false, false, true, false])
        XCTAssertEqual(rows[4].action, .show("tok1"))
    }

    func testTheRunnerRowShowsAnExistingRunner() {
        let rows = RtMenuModel.rows(hasRunner: true, runItems: [])
        XCTAssertEqual(rows.last?.title, "Show runner")
        XCTAssertEqual(rows.last?.action, .open(.runner))
    }

    func testStripsSayWhatHappened() {
        XCTAssertEqual(RtStrip.exited(1).text, "exited 1 · any key closes")
        XCTAssertEqual(RtStrip.exited(nil).text, "exited · any key closes")
        XCTAssertEqual(RtStrip.finished(0).text, "finished · exit 0 · any key closes")
        XCTAssertEqual(RtStrip.finished(nil).text, "finished · any key closes")
    }

    func testTheModalTitleNamesTheCommandAndAShortFolder() {
        XCTAssertEqual(item(kind: .nav, title: "nav").modalTitle(home: "/Users/acme"), "nav · ~/src/app")
        XCTAssertEqual(item().modalTitle(home: "/Users/acme"), "pnpm run test · ~/src/app")
        XCTAssertEqual(item(kind: .glitter).modalTitle(home: "/Users/other"), "glitter · /Users/acme/src/app")
    }
}

final class RtModalKeyTests: XCTestCase {
    func testCommandWClosesTheModal() {
        XCTAssertEqual(RtModalKey.decide(characters: "w", command: true, shift: false, option: false, control: false, stripShown: false), .close)
    }

    func testOtherCommandsPassEvenWithAStripUp() {
        XCTAssertEqual(RtModalKey.decide(characters: "q", command: true, shift: false, option: false, control: false, stripShown: true), .pass)
        XCTAssertEqual(RtModalKey.decide(characters: "w", command: true, shift: true, option: false, control: false, stripShown: false), .pass)
    }

    func testWithAStripUpAnyPlainKeyCloses() {
        XCTAssertEqual(RtModalKey.decide(characters: "a", command: false, shift: false, option: false, control: false, stripShown: true), .close)
        XCTAssertEqual(RtModalKey.decide(characters: "a", command: false, shift: false, option: false, control: false, stripShown: false), .pass)
    }
}
