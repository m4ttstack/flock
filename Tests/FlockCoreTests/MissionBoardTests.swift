import XCTest
@testable import FlockCore

final class MissionBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private typealias W = MissionFixture.Workspace
    private typealias T = MissionFixture.Tab
    private typealias P = MissionFixture.Pane

    private func board(
        _ model: SessionModel, toasts: AttentionToastStack = AttentionToastStack(),
        changedAgo: [String: TimeInterval] = [:], board names: BoardWorkspaceNames? = nil
    ) -> MissionBoard {
        MissionBoard(
            model: model, sections: RailSections(model: model, board: names), toasts: toasts,
            history: history(model, changedAgo: changedAgo), cutoff: 30 * 60, now: now
        )
    }

    private func history(_ model: SessionModel, changedAgo: [String: TimeInterval]) -> PaneStatusHistory {
        var history = PaneStatusHistory()
        // Every pane first seen two hours ago, then any listed pane changed
        // to its current status `changedAgo` seconds before now.
        var quiet = model
        for id in changedAgo.keys { quiet.panes[PaneID(rawValue: id)]?.agentStatus = .unknown }
        history.observe(quiet, at: now.addingTimeInterval(-7200))
        for (id, ago) in changedAgo.sorted(by: { $0.value > $1.value }) {
            var step = quiet
            step.panes[PaneID(rawValue: id)]?.agentStatus = model.panes[PaneID(rawValue: id)]!.agentStatus
            quiet = step
            history.observe(step, at: now.addingTimeInterval(-ago))
        }
        return history
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
        XCTAssertEqual(b.needsYou.map(\.paneID.rawValue), ["w1:t1:p1", "w1:t1:p2"])
        XCTAssertEqual(b.needsYou.first?.since, now.addingTimeInterval(-600))
        XCTAssertEqual(b.working.flatMap(\.cards).map(\.paneID.rawValue), ["w1:t1:p3"])
    }

    func testABlockedPaneWhoseCardWasClearedCoolsDownInstead() {
        let b = board(MissionFixture.single([.blocked]), changedAgo: ["w1:t1:p1": 120])
        XCTAssertTrue(b.needsYou.isEmpty)
        XCTAssertEqual(b.coolingDown.map(\.paneID.rawValue), ["w1:t1:p1"])
    }

    func testThePaneAtTheCutoffStillCoolsAndOnePastItIsDormant() {
        let b = board(MissionFixture.single([.idle, .idle]), changedAgo: ["w1:t1:p1": 30 * 60, "w1:t1:p2": 30 * 60 + 1])
        XCTAssertEqual(b.coolingDown.map(\.paneID.rawValue), ["w1:t1:p1"])
        XCTAssertEqual(b.dormant.map(\.paneID.rawValue), ["w1:t1:p2"])
    }

    func testAWorkingPaneIsNeverDormantHoweverLongItWorks() {
        let b = board(MissionFixture.single([.working]))
        XCTAssertEqual(b.working.flatMap(\.cards).count, 1)
        XCTAssertTrue(b.dormant.isEmpty)
    }

    func testCoolingDownIsMostRecentChangeFirst() {
        let b = board(MissionFixture.single([.idle, .done]), changedAgo: ["w1:t1:p1": 600, "w1:t1:p2": 60])
        XCTAssertEqual(b.coolingDown.map(\.paneID.rawValue), ["w1:t1:p2", "w1:t1:p1"])
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

    func testAWorkspaceIsDormantOnlyWhenEveryPaneIs() {
        let model = MissionFixture.model([
            W(label: "quiet", tabs: [T(label: "a", panes: [P(status: .unknown), P(status: .idle)])]),
            W(label: "busy", tabs: [T(label: "b", panes: [P(status: .idle), P(status: .working)])]),
        ])
        let b = board(model)
        XCTAssertEqual(b.dormantWorkspaces, [WorkspaceID(rawValue: "w1")])
    }

    /// A shell-only workspace never changes status, so it passes the cutoff
    /// while the user works in it; Arrange still draws it as an island.
    func testArrangeNeverFoldsTheWorkspaceYouAreIn() {
        let model = MissionFixture.model([
            W(label: "shells", tabs: [T(label: "a", panes: [P(status: .unknown, title: "zsh")])]),
            W(label: "quiet", tabs: [T(label: "b", panes: [P(status: .idle)])]),
        ])
        let b = board(model)
        let shells = WorkspaceID(rawValue: "w1")
        XCTAssertEqual(b.dormantWorkspaces, Set([shells, WorkspaceID(rawValue: "w2")]), "the premise: both are dormant")
        XCTAssertEqual(b.arrangeDormantWorkspaces(focused: shells), [WorkspaceID(rawValue: "w2")])
        XCTAssertEqual(b.arrangeDormantWorkspaces(focused: nil), b.dormantWorkspaces)
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
        XCTAssertEqual(MissionSelection.resolve(gone, in: columns), a, "a dormant or closed pane is not kept")
        XCTAssertEqual(MissionSelection.resolve(nil, in: columns), a)
        XCTAssertNil(MissionSelection.resolve(gone, in: [[], [], []]), "no drawn card, nothing to select or open")
    }

    func testCardFindsAPaneInWhicheverLaneHoldsIt() {
        let model = MissionFixture.single([.blocked, .working, .idle, .idle])
        var toasts = AttentionToastStack()
        toasts.raise(toast("w1:t1:p1", .needsInput, raised: 600))
        let b = board(model, toasts: toasts, changedAgo: ["w1:t1:p3": 120])
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p1")), b.needsYou.first)
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p2")), b.working.first?.cards.first)
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p3")), b.coolingDown.first)
        XCTAssertEqual(b.card(PaneID(rawValue: "w1:t1:p4")), b.dormant.first)
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
        let card = board(MissionFixture.single([.blocked]), changedAgo: ["w1:t1:p1": 12 * 60]).coolingDown[0]
        XCTAssertEqual(card.stateText(at: now), "blocked 12m")
        let unrecorded = MissionCard(
            paneID: card.paneID, workspaceID: card.workspaceID, tabID: card.tabID, workspaceName: "", tabTitle: "",
            title: "", status: .working, since: nil, folder: ""
        )
        XCTAssertEqual(unrecorded.stateText(at: now), "working")
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
