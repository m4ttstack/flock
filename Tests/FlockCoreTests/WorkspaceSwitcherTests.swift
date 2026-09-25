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

    func testKeys() {
        typealias Key = WorkspaceSwitcherKey
        let tab: UInt16 = 48
        XCTAssertEqual(Key.decide(keyCode: tab, control: true, shift: false, command: false, option: false, active: false), .next)
        XCTAssertEqual(Key.decide(keyCode: tab, control: true, shift: true, command: false, option: false, active: false), .previous)
        XCTAssertEqual(Key.decide(keyCode: tab, control: false, shift: false, command: false, option: false, active: false), .pass)
        XCTAssertEqual(Key.decide(keyCode: tab, control: true, shift: false, command: true, option: false, active: false), .pass)
        XCTAssertEqual(Key.decide(keyCode: tab, control: true, shift: false, command: false, option: true, active: false), .pass)
        XCTAssertEqual(Key.decide(keyCode: 53, control: true, shift: false, command: false, option: false, active: true), .cancel)
        XCTAssertEqual(Key.decide(keyCode: 36, control: true, shift: false, command: false, option: false, active: true), .commit)
        XCTAssertEqual(Key.decide(keyCode: 125, control: true, shift: false, command: false, option: false, active: true), .next)
        XCTAssertEqual(Key.decide(keyCode: 126, control: true, shift: false, command: false, option: false, active: true), .previous)
        XCTAssertEqual(Key.decide(keyCode: 0, control: true, shift: false, command: false, option: false, active: true), .swallow)
        XCTAssertEqual(Key.decide(keyCode: 53, control: false, shift: false, command: false, option: false, active: false), .pass)
    }
}
