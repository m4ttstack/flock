import XCTest
@testable import FlockCore

/// One test per row of herdr's own prefix-mode table
/// (`src/client/shell/input.rs`, the `ClientShellMode::Terminal` and
/// `ClientShellMode::Prefix` arms).
final class PrefixKeyMachineTests: XCTestCase {
    private let prefix = HerdrKeyPress(code: .character("b"), modifiers: .control)

    private func press(_ character: Character, _ modifiers: HerdrKeyModifiers = []) -> HerdrKeyPress {
        HerdrKeyPress(code: .character(character), modifiers: modifiers)
    }

    func testAnUnboundKeyInTerminalModeGoesToThePane() {
        var machine = PrefixKeyMachine()
        XCTAssertEqual(machine.handle(press("a")), .sendToPane)
        XCTAssertEqual(machine.mode, .terminal)
    }

    /// The prefix press itself never reaches the program.
    func testThePrefixKeyEntersPrefixModeAndIsNotSent() {
        var machine = PrefixKeyMachine()
        XCTAssertEqual(machine.handle(prefix), .enteredPrefix)
        XCTAssertEqual(machine.mode, .prefix)
    }

    func testABoundSecondKeyRunsItsActionAndLeavesPrefixMode() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        guard case .run(let binding) = machine.handle(press("c")) else {
            return XCTFail("prefix+c is bound to new_tab")
        }
        XCTAssertEqual(binding.action, .newTab)
        XCTAssertEqual(binding.label, "prefix+c")
        XCTAssertEqual(machine.mode, .terminal)
    }

    /// How a literal prefix key reaches the program: press it twice.
    func testThePrefixPressedTwiceSendsItToThePane() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        XCTAssertEqual(machine.mode, .prefix)
        XCTAssertEqual(machine.handle(prefix), .sendToPane)
        XCTAssertEqual(machine.mode, .terminal)
    }

    func testEscLeavesPrefixModeAndSendsNothing() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        XCTAssertEqual(machine.handle(HerdrKeyPress(code: .escape)), .swallow)
        XCTAssertEqual(machine.mode, .terminal)
    }

    /// An unbound second key is eaten, not passed on: herdr never types the
    /// key that followed a prefix into the program.
    func testAnUnboundSecondKeyIsSwallowed() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        XCTAssertEqual(machine.handle(press("y")), .swallow)
        XCTAssertEqual(machine.mode, .terminal)
    }

    func testPrefixModeSurvivesUntilTheNextKey() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        XCTAssertEqual(machine.mode, .prefix)
        XCTAssertEqual(machine.mode, .prefix)
    }

    func testADirectBindingRunsWithNoPrefixAheadOfIt() {
        var machine = PrefixKeyMachine(
            keybindings: HerdrKeybindings.read(configText: """
                [keys]
                next_tab = "ctrl+n"
                """)
        )
        guard case .run(let binding) = machine.handle(press("n", .control)) else {
            return XCTFail("ctrl+n is bound directly")
        }
        XCTAssertEqual(binding.action, .nextTab)
        XCTAssertEqual(machine.mode, .terminal)
    }

    func testARebuiltKeymapDropsOutOfPrefixMode() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        XCTAssertEqual(machine.mode, .prefix)
        machine.update(keybindings: HerdrKeybindings.read(configText: """
            [keys]
            prefix = "ctrl+a"
            """))
        XCTAssertEqual(machine.mode, .terminal)
    }

    func testAnUnchangedKeymapLeavesPrefixModeAlone() {
        var machine = PrefixKeyMachine()
        _ = machine.handle(prefix)
        machine.update(keybindings: .defaults)
        XCTAssertEqual(machine.mode, .prefix)
    }
}
