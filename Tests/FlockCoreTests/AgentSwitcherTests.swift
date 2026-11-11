import XCTest
@testable import FlockCore

@MainActor
final class AgentSwitcherTests: XCTestCase {
    private nonisolated static let suite = "AgentSwitcherTests"
    private let a = PaneID(rawValue: "w1:p1")
    private let b = PaneID(rawValue: "w2:p3")
    private let shell = PaneID(rawValue: "w1:p2")

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func makeSwitcher() -> AgentSwitcher {
        AgentSwitcher(userDefaults: UserDefaults(suiteName: Self.suite)!)
    }

    func testFromAnAgentAQuickTapGoesBackToTheLastOne() {
        let switcher = makeSwitcher()
        switcher.note(b)
        switcher.note(a)
        switcher.begin(items: [a, b], current: a)
        XCTAssertEqual(switcher.finish(), b)
    }

    func testFromAShellAQuickTapOpensTheMostRecentAgent() {
        let switcher = makeSwitcher()
        switcher.note(a)
        switcher.note(b)
        switcher.begin(items: [a, b], current: shell)
        XCTAssertEqual(switcher.order, [b, a])
        XCTAssertEqual(switcher.finish(), b)
    }

    func testFromAShellOneAgentIsEnoughButNoneIsNot() {
        let switcher = makeSwitcher()
        switcher.begin(items: [a], current: shell)
        XCTAssertFalse(switcher.isEmpty)
        XCTAssertEqual(switcher.finish(), a)
        switcher.begin(items: [], current: shell)
        XCTAssertTrue(switcher.isEmpty)
        switcher.cancel()
        switcher.begin(items: [a], current: a)
        XCTAssertTrue(switcher.isEmpty, "the only agent is already here")
        XCTAssertNil(switcher.finish())
    }

    func testCommandBacktickKeys() {
        func decide(command: Bool = true, control: Bool = false, option: Bool = false, shift: Bool = false, key: UInt16 = 50)
            -> SwitcherKey.Decision
        {
            SwitcherKey.decide(
                trigger: .commandBacktick, keyCode: key, control: control, shift: shift, command: command, option: option,
                active: false
            )
        }
        XCTAssertEqual(decide(), .next)
        XCTAssertEqual(decide(shift: true), .previous)
        XCTAssertEqual(decide(command: false), .pass)
        XCTAssertEqual(decide(option: true), .pass)
        XCTAssertEqual(decide(key: 48), .pass)
        XCTAssertEqual(
            SwitcherKey.decide(trigger: .controlBacktick, keyCode: 50, control: true, shift: false, command: true, option: false, active: false),
            .pass, "⌃⌘` is not ⌃`"
        )
        XCTAssertTrue(SwitcherKey.isHeld(.commandBacktick, control: false, option: false, command: true))
        XCTAssertFalse(SwitcherKey.isHeld(.commandBacktick, control: true, option: false, command: false))
    }
}
