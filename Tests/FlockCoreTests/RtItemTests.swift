import XCTest
@testable import FlockCore

final class RtItemTests: XCTestCase {
    private func item(kind: RtKind = .run, title: String = "pnpm run test", running: Bool = true, strip: RtStrip? = nil) -> RtItem {
        RtItem(
            id: "tok1", kind: kind, linked: TerminalID(rawValue: "term_a1"), workspaceID: WorkspaceID(rawValue: "wF"),
            tabID: TabID(rawValue: "wF:t1"), firstPaneID: PaneID(rawValue: "wF:p1"),
            title: title, folder: "/Users/acme/src/app", isRunning: running, started: true, strip: strip
        )
    }

    func testTheButtonRestsWithNothingRunningAndCountsRunItemsOnly() {
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: false, runningItems: 3, hasRunner: true), .absent)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 0, hasRunner: false), .rest)
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: false), .active(count: 2, runner: false))
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 2, hasRunner: true), .active(count: 2, runner: true))
        XCTAssertEqual(RtButtonModel.appearance(rtInstalled: true, runningItems: 0, hasRunner: true), .active(count: 0, runner: true))
    }

    func testThePopoverOffersFiveCommandsWithRtsOwnCommandAsAHint() {
        let rows = RtPopoverModel.commands(hasRunner: false)
        XCTAssertEqual(rows.map(\.title), ["Change directory", "Browse files", "Review and commit", "Run a script…", "Start runner"])
        XCTAssertEqual(rows.map(\.hint), ["rt cd", "rt nav", "rt glitter", "rt run", "rt runner"])
        XCTAssertEqual(rows.map(\.kind), [.cd, .nav, .glitter, .run, .runner])
        XCTAssertEqual(RtPopoverModel.commands(hasRunner: true).last?.title, "Show runner")
    }

    func testARunRowSaysWhereTheItemIs() {
        XCTAssertEqual(item().runRow, RtRunRow(id: "tok1", title: "pnpm run test", state: "running", tone: .running))
        XCTAssertEqual(item(running: false, strip: .finished(0)).runRow.state, "finished · exit 0")
        XCTAssertEqual(item(running: false, strip: .finished(nil)).runRow.state, "finished")
        XCTAssertEqual(item(running: false, strip: .exited(1)).runRow, RtRunRow(id: "tok1", title: "pnpm run test", state: "exited 1", tone: .exited))
        XCTAssertEqual(item(running: false, strip: .exited(nil)).runRow.state, "exited")
        XCTAssertEqual(item(running: false).runRow.tone, .finished)
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

    func testAFolderUnderHomeReadsFromATilde() {
        XCTAssertEqual(RtPaths.tilde("/Users/acme", home: "/Users/acme"), "~")
        XCTAssertEqual(RtPaths.tilde("/Users/acme/src/app", home: "/Users/acme"), "~/src/app")
        XCTAssertEqual(RtPaths.tilde("/Users/acme2/src", home: "/Users/acme"), "/Users/acme2/src")
        XCTAssertEqual(RtPaths.tilde("/tmp", home: "/Users/acme"), "/tmp")
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
