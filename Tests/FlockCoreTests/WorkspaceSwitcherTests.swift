import XCTest
@testable import FlockCore

@MainActor
final class WorkspaceSwitcherTests: XCTestCase {
    private nonisolated static let suite = "WorkspaceSwitcherTests"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func makeSwitcher() -> WorkspaceSwitcher {
        WorkspaceSwitcher(userDefaults: UserDefaults(suiteName: Self.suite)!)
    }

    private func ids(_ names: String...) -> [WorkspaceID] { names.map { WorkspaceID(rawValue: $0) } }

    func testRecentsSurviveARelaunchAndStayCapped() {
        let switcher = makeSwitcher()
        for index in 0..<(WorkspaceSwitcher.storedLimit + 5) { switcher.note(WorkspaceID(rawValue: "w\(index)")) }
        let reread = makeSwitcher()
        XCTAssertEqual(reread.recents.count, WorkspaceSwitcher.storedLimit)
        XCTAssertEqual(reread.recents.first, WorkspaceID(rawValue: "w\(WorkspaceSwitcher.storedLimit + 4)"))
    }

    func testRecentsPutTheLatestFirstWithoutRepeats() {
        let switcher = makeSwitcher()
        for name in ["a", "b", "a", "c"] { switcher.note(WorkspaceID(rawValue: name)) }
        XCTAssertEqual(switcher.recents, ids("c", "a", "b"))
    }

    func testTheOrderLeadsWithTheCurrentWorkspaceThenRecentsThenTheRest() {
        let switcher = makeSwitcher()
        for name in ["d", "b", "c"] { switcher.note(WorkspaceID(rawValue: name)) }
        XCTAssertTrue(switcher.begin(workspaces: ids("a", "b", "c", "d", "e"), current: WorkspaceID(rawValue: "c")))
        XCTAssertEqual(switcher.order, ids("c", "b", "d", "a", "e"))
    }

    func testARecentThatNoLongerExistsIsLeftOut() {
        let switcher = makeSwitcher()
        for name in ["gone", "a"] { switcher.note(WorkspaceID(rawValue: name)) }
        switcher.begin(workspaces: ids("a", "b"), current: WorkspaceID(rawValue: "a"))
        XCTAssertEqual(switcher.order, ids("a", "b"))
    }

    private func record(_ id: String, _ label: String) -> WorkspaceRecord {
        WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: id), label: label, number: 1,
            activeTabID: TabID(rawValue: "\(id):t1"), agentStatus: .idle)
    }

    func testPinsLeadTheCandidatesAndAnEmptyPinHasASwitcherID() {
        let live = PinnedWorkspace(id: PinID(rawValue: "p1"), name: "web", folder: "/web", workspace: WorkspaceID(rawValue: "w2"), syncedLabel: "web", confirmed: true)
        let empty = PinnedWorkspace(id: PinID(rawValue: "p2"), name: "notes", folder: "/notes", workspace: nil, syncedLabel: nil, confirmed: false)
        let workspaces = [record("w1", "acme"), record("w2", "web")]
        let ids = WorkspaceSwitcher.candidates(workspaces, current: nil, pins: [live, empty])
        XCTAssertEqual(ids.map(\.rawValue), ["w2", "pin:p2", "w1"])
        XCTAssertEqual(PinID(switcherID: ids[1]), PinID(rawValue: "p2"))
        XCTAssertNil(PinID(switcherID: ids[0]))
    }

    /// A pin linked to a workspace herdr does not report is drawn empty, so
    /// it is offered empty; every candidate is then a record or a pin, and
    /// each has a row.
    func testAPinLinkedToAnUnreportedWorkspaceIsOfferedEmpty() {
        let stale = PinnedWorkspace(id: PinID(rawValue: "p1"), name: "web", folder: "/web", workspace: WorkspaceID(rawValue: "w9"), syncedLabel: nil, confirmed: false)
        let workspaces = [record("w1", "acme")]
        let ids = WorkspaceSwitcher.candidates(workspaces, current: WorkspaceID(rawValue: "w1"), pins: [stale])
        XCTAssertEqual(ids.map(\.rawValue), ["pin:p1", "w1"])

        let switcher = makeSwitcher()
        switcher.note(WorkspaceID(rawValue: "w9"))
        XCTAssertTrue(switcher.begin(workspaces: ids, current: WorkspaceID(rawValue: "w1")))
        XCTAssertEqual(switcher.order.map(\.rawValue), ["w1", "pin:p1"])
        XCTAssertEqual(switcher.selected, stale.switcherID)
    }

    func testAHerdIsNeverOnOffer() {
        let switcher = makeSwitcher()
        for name in ["h", "b"] { switcher.note(WorkspaceID(rawValue: name)) }
        let workspaces = [record("a", "flock"), record("h", "herd: 7f3a"), record("b", "rt")]

        switcher.begin(workspaces: WorkspaceSwitcher.candidates(workspaces, current: WorkspaceID(rawValue: "a")), current: WorkspaceID(rawValue: "a"))

        XCTAssertEqual(switcher.order, ids("a", "b"))
    }

    func testFromInsideAHerdATapStillGoesBack() {
        let switcher = makeSwitcher()
        for name in ["a", "g", "b", "h"] { switcher.note(WorkspaceID(rawValue: name)) }
        let workspaces = [record("a", "flock"), record("g", "herd: 91c0"), record("h", "herd: 7f3a"), record("b", "rt")]

        switcher.begin(workspaces: WorkspaceSwitcher.candidates(workspaces, current: WorkspaceID(rawValue: "h")), current: WorkspaceID(rawValue: "h"))

        XCTAssertEqual(switcher.order, ids("h", "b", "a"))
        XCTAssertEqual(switcher.finish(), WorkspaceID(rawValue: "b"))
    }

    func testItStartsOnThePreviousWorkspaceAndATapGoesBack() {
        let switcher = makeSwitcher()
        for name in ["a", "b"] { switcher.note(WorkspaceID(rawValue: name)) }
        switcher.begin(workspaces: ids("a", "b", "c"), current: WorkspaceID(rawValue: "b"))
        XCTAssertEqual(switcher.selected, WorkspaceID(rawValue: "a"))
        XCTAssertEqual(switcher.finish(), WorkspaceID(rawValue: "a"))
        XCTAssertFalse(switcher.isActive)
    }

    func testShiftStartsAtTheEndAndStepsWrap() {
        let switcher = makeSwitcher()
        switcher.begin(workspaces: ids("a", "b", "c"), current: WorkspaceID(rawValue: "a"), reverse: true)
        XCTAssertEqual(switcher.selected, WorkspaceID(rawValue: "c"))
        switcher.step(1)
        XCTAssertEqual(switcher.selected, WorkspaceID(rawValue: "a"))
        switcher.step(-1)
        XCTAssertEqual(switcher.selected, WorkspaceID(rawValue: "c"))
    }

    func testLandingBackOnTheCurrentWorkspaceGoesNowhere() {
        let switcher = makeSwitcher()
        switcher.begin(workspaces: ids("a", "b"), current: WorkspaceID(rawValue: "a"))
        switcher.step(1)
        XCTAssertNil(switcher.finish())
    }

    func testOneWorkspaceHasNothingToSwitchTo() {
        let switcher = makeSwitcher()
        XCTAssertFalse(switcher.begin(workspaces: ids("a"), current: WorkspaceID(rawValue: "a")))
        XCTAssertFalse(switcher.isActive)
    }

    func testThePanelShowsOnlyForTheSessionThatAskedAndCancelHidesIt() {
        let switcher = makeSwitcher()
        switcher.begin(workspaces: ids("a", "b"), current: WorkspaceID(rawValue: "a"))
        let first = switcher.session
        switcher.cancel()
        switcher.begin(workspaces: ids("a", "b"), current: WorkspaceID(rawValue: "a"))
        switcher.show(session: first)
        XCTAssertFalse(switcher.isShown)
        switcher.show(session: switcher.session)
        XCTAssertTrue(switcher.isShown)
        switcher.cancel()
        XCTAssertFalse(switcher.isShown)
        XCTAssertFalse(switcher.isActive)
    }

    func testControlKeys() {
        func decide(_ keyCode: UInt16, control: Bool = true, shift: Bool = false, command: Bool = false, option: Bool = false, active: Bool = false)
            -> SwitcherKey.Decision {
            SwitcherKey.decide(
                trigger: .control, keyCode: keyCode, control: control, shift: shift, command: command, option: option, active: active
            )
        }
        let tab: UInt16 = 48
        XCTAssertEqual(decide(tab), .next)
        XCTAssertEqual(decide(tab, shift: true), .previous)
        XCTAssertEqual(decide(tab, control: false), .pass)
        XCTAssertEqual(decide(tab, command: true), .pass)
        XCTAssertEqual(decide(tab, option: true), .pass)
        XCTAssertEqual(decide(53, active: true), .cancel)
        XCTAssertEqual(decide(36, active: true), .commit)
        XCTAssertEqual(decide(125, active: true), .next)
        XCTAssertEqual(decide(126, active: true), .previous)
        XCTAssertEqual(decide(0, active: true), .swallow)
        XCTAssertEqual(decide(53, control: false), .pass)
    }

    func testOptionKeysAreTheTabSwitchers() {
        func decide(_ keyCode: UInt16, control: Bool = false, shift: Bool = false, command: Bool = false, option: Bool = true, active: Bool = false)
            -> SwitcherKey.Decision {
            SwitcherKey.decide(
                trigger: .option, keyCode: keyCode, control: control, shift: shift, command: command, option: option, active: active
            )
        }
        let tab: UInt16 = 48
        XCTAssertEqual(decide(tab), .next)
        XCTAssertEqual(decide(tab, shift: true), .previous)
        XCTAssertEqual(decide(tab, option: false), .pass)
        XCTAssertEqual(decide(tab, control: true), .pass, "⌃⌥Tab is neither switcher's")
        XCTAssertEqual(decide(tab, command: true), .pass)
        XCTAssertEqual(decide(53, active: true), .cancel)
    }

    /// The seed fixture's `w1:t1` carries herdr's default label, its own
    /// number; `w1:t2` is named.
    func testAnUnnamedTabShowsItsFocusedPaneInBrackets() throws {
        let model = SessionModel(snapshot: try HerdrDecoder.snapshot(fromResponseLine: try fixture("snapshot.json")))
        let tabs = try XCTUnwrap(model.tabs[WorkspaceID(rawValue: "w1")])
        XCTAssertEqual(tabs.map { TabSwitcher.title(for: $0, in: model) }, ["[shell]", "tabB"])
    }

    func testTabRecentsKeepTheirOwnList() {
        let defaults = UserDefaults(suiteName: Self.suite)!
        let workspaces = WorkspaceSwitcher(userDefaults: defaults)
        let tabs = TabSwitcher(userDefaults: defaults)
        workspaces.note(WorkspaceID(rawValue: "w1"))
        tabs.note(TabID(rawValue: "w1:t2"))
        tabs.note(TabID(rawValue: "w1:t1"))
        XCTAssertEqual(TabSwitcher(userDefaults: defaults).recents.map(\.rawValue), ["w1:t1", "w1:t2"])
        XCTAssertEqual(WorkspaceSwitcher(userDefaults: defaults).recents.map(\.rawValue), ["w1"])

        XCTAssertTrue(tabs.begin(items: [TabID(rawValue: "w1:t1"), TabID(rawValue: "w1:t2"), TabID(rawValue: "w1:t3")], current: TabID(rawValue: "w1:t1")))
        XCTAssertEqual(tabs.order.map(\.rawValue), ["w1:t1", "w1:t2", "w1:t3"])
        XCTAssertEqual(tabs.selected?.rawValue, "w1:t2")
    }
}
