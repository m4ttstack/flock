import XCTest
@testable import FlockCore

final class PaneChromeTests: XCTestCase {
    func testOnlyClaudeCodeSitsFlush() {
        XCTAssertTrue(PaneChrome.isFlush(agent: "claude"))
        XCTAssertFalse(PaneChrome.isFlush(agent: "codex"))
        XCTAssertFalse(PaneChrome.isFlush(agent: nil))
    }

    func testAFlushPaneKeepsItsHeaderButDropsTheBottomAndMostOfTheSides() {
        XCTAssertEqual(PaneChrome.size(flush: false), PaneChrome.size)
        XCTAssertEqual(PaneChrome.size(flush: true), CGSize(width: 2 * PaneChrome.flushSidePadding, height: PaneChrome.contentTop))
        XCTAssertEqual(PaneChrome.size(flush: true), CGSize(width: 12, height: 54))
    }

    func testPaddingFollowsFlush() {
        XCTAssertEqual(PaneChrome.horizontalPadding(flush: false), PaneChrome.horizontalPadding)
        XCTAssertEqual(PaneChrome.horizontalPadding(flush: true), PaneChrome.flushSidePadding)
        XCTAssertEqual(PaneChrome.bottomPadding(flush: false), PaneChrome.verticalPadding)
        XCTAssertEqual(PaneChrome.bottomPadding(flush: true), 0)
    }

    func testOnlyAPaneWithNoAgentIsCompact() {
        XCTAssertTrue(PaneChrome.isCompact(agent: nil))
        XCTAssertFalse(PaneChrome.isCompact(agent: "claude"))
    }

    /// The status line sits as far under the title row as the box's top edge
    /// is above it.
    func testStatusLineMirrorsTheTitleRowsTopInset() {
        for compact in [false, true] {
            let rowCentre = PaneChrome.titleRowTop(compact: compact) + PaneChrome.titleRowHeight / 2
            XCTAssertEqual(PaneChrome.statusLineTop(compact: compact) - rowCentre, rowCentre, "compact: \(compact)")
        }
        XCTAssertEqual(PaneChrome.statusLineTop(compact: false), 48)
        XCTAssertEqual(PaneChrome.statusLineTop(compact: true), 34)
    }

    func testACompactHeaderIsShorterAndAFullOneKeepsTheStandardContentTop() {
        XCTAssertEqual(PaneChrome.contentTop(compact: false), PaneChrome.contentTop)
        XCTAssertEqual(PaneChrome.contentTop(compact: true), PaneChrome.statusLineTop(compact: true) + PaneChrome.compactGapBelowRule)
        XCTAssertEqual(PaneChrome.contentTop(compact: true), 40)
        XCTAssertEqual(PaneChrome.size(flush: false, compact: true), CGSize(width: 26, height: 44))
        XCTAssertEqual(PaneChrome.size(flush: true, compact: false), PaneChrome.size(flush: true))
    }

    /// A shell beside an agent takes the agent's full header so the title
    /// rows line up; a shell under it, or beside only shells, stays compact.
    func testAShellSharingAnAgentsRowTakesTheFullHeader() {
        let agent = PaneID(rawValue: "p1"), beside = PaneID(rawValue: "p2")
        let below = PaneID(rawValue: "p3"), lone = PaneID(rawValue: "p4")
        let compact = PaneChrome.compactPanes([
            (id: agent, agent: "claude", top: 0),
            (id: beside, agent: nil, top: 0.5),
            (id: below, agent: nil, top: 300),
            (id: lone, agent: nil, top: 300),
        ])
        XCTAssertEqual(compact, [below, lone])
    }
}
