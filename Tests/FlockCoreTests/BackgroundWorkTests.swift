import XCTest
@testable import FlockCore

/// Screens shaped as Claude Code paints them: the transcript, the prompt box
/// between two rules, then the status line and the footer below the bottom
/// rule.
enum FooterFixture {
    static let rule = String(repeating: "─", count: 80)
    static let composer = ["", rule, "❯ ", rule, "  O 5.5 [high] | claude | acme-api ███░░░ 2/6 | W:40% C:15%"]

    static func screen(_ footer: String..., above: [String] = []) -> String {
        (above + composer + footer).joined(separator: "\n")
    }

    static let shell = screen("  ⏵⏵ auto mode on · 1 shell · ← for agents")
    static let shellAndMonitor = screen("  ⏵⏵ auto mode on · 1 shell, 1 monitor · ← for agents")
    static let monitors = screen("  ⏵⏵ auto mode on · 2 monitors · ← for agents")
    static let plain = screen("  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents")
    static let transcriptMention = screen(
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
        above: ["⏺ Started 2 shells and 1 monitor for the acme CI wait."]
    )
    static let agentsPanel = screen(
        "  ⏵⏵ auto mode on · ← for agents", "", "  ⏺ main",
        "  ◯ general-purpose  Throwaway footer… 5s · ↓ 49.3k tokens"
    )

    /// A working pane running one shell and one subagent, as captured, with
    /// the names swapped for acme's.
    static let captured = """
    ⏺ Capturing the acme-api pane footer to a fixture file
      ⎿  $ rt pane peek w1:p3 --lines 14 > /tmp/acme/captured-footer.txt

    ✻ Transfiguring… (34s · ↓ 2.6k tokens)

    \(rule)
    ❯
    \(rule)
      O 5.5 [high] | claude | acme-api ███░░░░░░░ 2/6 | W:40% C:15%
      ⏵⏵ auto mode on · 1 shell · /tasks to see subagents · ← for agents

      ⏺ main
      ◯ general-purpose  Implement Task 3: acme exemptions                     16s · ↓ 78.4k tokens
    """
}

final class BackgroundWorkTests: XCTestCase {
    func testAShellOrMonitorCountInTheFooterIsTheReason() {
        XCTAssertEqual(BackgroundWork.reason(in: FooterFixture.shell), "1 shell")
        XCTAssertEqual(BackgroundWork.reason(in: FooterFixture.shellAndMonitor), "1 shell, 1 monitor")
        XCTAssertEqual(BackgroundWork.reason(in: FooterFixture.monitors), "2 monitors")
    }

    func testAPlainFooterHasNoReason() {
        XCTAssertNil(BackgroundWork.reason(in: FooterFixture.plain))
    }

    func testACountAboveTheComposersLastRuleIsTranscriptNotFooter() {
        XCTAssertNil(BackgroundWork.reason(in: FooterFixture.transcriptMention))
    }

    func testAScreenWithNoRuleHasNoReason() {
        XCTAssertNil(BackgroundWork.reason(in: "  ⏵⏵ auto mode on · 1 shell · ← for agents"))
        XCTAssertNil(BackgroundWork.reason(in: ""))
    }

    func testAShortRuleIsNotTheComposers() {
        let screen = ["❯ ", "─────────", "  ⏵⏵ auto mode on · 1 shell"].joined(separator: "\n")
        XCTAssertNil(BackgroundWork.reason(in: screen))
    }

    func testAZeroCountIsNoWork() {
        XCTAssertNil(BackgroundWork.reason(in: FooterFixture.screen("  ⏵⏵ auto mode on · 0 shells")))
    }

    func testTheAgentsPanelCountsItsSubagents() {
        XCTAssertEqual(BackgroundWork.reason(in: FooterFixture.agentsPanel), "1 subagent")
        let two = FooterFixture.agentsPanel + "\n  ◯ Explore  Find the acme handlers 3s · ↓ 1.2k tokens\n\n"
        XCTAssertEqual(BackgroundWork.reason(in: two), "2 subagents")
    }

    func testAnAgentsPanelWithNoRowsIsNoWork() {
        XCTAssertNil(BackgroundWork.reason(in: FooterFixture.screen("  ⏵⏵ auto mode on · ← for agents", "", "  ⏺ main", "")))
    }

    func testTheCapturedScreenReadsByItsCountThenItsPanelThenNothing() {
        let captured = FooterFixture.captured
        XCTAssertEqual(BackgroundWork.reason(in: captured), "1 shell")
        let withoutCount = captured.replacingOccurrences(of: "1 shell · ", with: "")
        XCTAssertNotEqual(withoutCount, captured)
        XCTAssertEqual(BackgroundWork.reason(in: withoutCount), "1 subagent")
        let withoutPanel = withoutCount.components(separatedBy: "\n")
            .filter { !$0.contains("⏺ main") && !$0.contains("◯ ") }
            .joined(separator: "\n")
        XCTAssertTrue(withoutPanel.contains("⏺ Capturing"), "the transcript's own ⏺ line is above the rules")
        XCTAssertNil(BackgroundWork.reason(in: withoutPanel))
    }

    // MARK: - eligibility and the shown status

    private func pane(_ status: AgentStatus, agent: String? = "claude", id: String = "w1:t1:p1", tab: String = "w1:t1") -> PaneRecord {
        var record = PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: tab),
            focused: false, agentStatus: status, revision: 0, terminalTitleStripped: "claude", label: nil,
            cwd: "/tmp/acme", scroll: nil
        )
        record.agent = agent
        return record
    }

    func testOnlyAClaudePaneBetweenTurnsIsEligible() {
        XCTAssertTrue(BackgroundWork.isEligible(pane(.idle)))
        XCTAssertTrue(BackgroundWork.isEligible(pane(.done)))
        XCTAssertFalse(BackgroundWork.isEligible(pane(.working)))
        XCTAssertFalse(BackgroundWork.isEligible(pane(.blocked)))
        XCTAssertFalse(BackgroundWork.isEligible(pane(.unknown)))
        XCTAssertFalse(BackgroundWork.isEligible(pane(.idle, agent: "codex")))
        XCTAssertFalse(BackgroundWork.isEligible(pane(.idle, agent: nil)))
    }

    func testAnEligiblePaneWithWorkShowsAsWorkingWithItsReason() {
        let shown = ShownStatus.of(pane(.idle), backgroundWork: [PaneID(rawValue: "w1:t1:p1"): "1 shell"])
        XCTAssertEqual(shown.status, .working)
        XCTAssertTrue(shown.isBackground)
        XCTAssertEqual(shown.word, "working · 1 shell")
    }

    func testAStaleEntryNeverRelabelsAPaneThatLeftEligibility() {
        let work = [PaneID(rawValue: "w1:t1:p1"): "1 shell"]
        XCTAssertEqual(ShownStatus.of(pane(.blocked), backgroundWork: work), ShownStatus(.blocked))
        XCTAssertEqual(ShownStatus.of(pane(.working), backgroundWork: work), ShownStatus(.working))
        XCTAssertEqual(ShownStatus.of(pane(.idle), backgroundWork: [:]), ShownStatus(.idle))
    }

    func testAGroupShowsBackgroundWorkUnlessSomethingLouderIsGoingOn() {
        let busy = pane(.idle, id: "w1:t1:p1")
        let work = [busy.paneID: "1 shell"]
        XCTAssertTrue(ShownStatus.aggregate(herdr: .idle, panes: [busy, pane(.idle, id: "w1:t1:p2")], backgroundWork: work).isBackground)
        XCTAssertTrue(
            ShownStatus.aggregate(herdr: .done, panes: [pane(.done, id: "w1:t1:p1")], backgroundWork: work).isBackground,
            "the only done pane is the one still busy"
        )
        XCTAssertEqual(
            ShownStatus.aggregate(herdr: .working, panes: [busy, pane(.working, id: "w1:t1:p2")], backgroundWork: work),
            ShownStatus(.working), "a pane really working outranks background work"
        )
        XCTAssertEqual(
            ShownStatus.aggregate(herdr: .blocked, panes: [busy, pane(.blocked, id: "w1:t1:p2")], backgroundWork: work),
            ShownStatus(.blocked)
        )
        XCTAssertEqual(ShownStatus.aggregate(herdr: .idle, panes: [pane(.idle, id: "w1:t1:p2")], backgroundWork: work), ShownStatus(.idle))
    }
}
