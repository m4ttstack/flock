import XCTest
@testable import FlockCore

/// Pins the table against herdr's `validated_keybinds`: which key runs which
/// action, and which of two bindings for one key survives.
final class HerdrKeybindingsTests: XCTestCase {
    private func prefixed(_ keys: HerdrKeybindings, _ combo: String) -> HerdrAction? {
        guard let parsed = HerdrKeyCombo.parse(combo) else { return nil }
        return keys.prefixed(matching: press(parsed))?.action
    }

    private func direct(_ keys: HerdrKeybindings, _ combo: String) -> HerdrAction? {
        guard let parsed = HerdrKeyCombo.parse(combo) else { return nil }
        return keys.direct(matching: press(parsed))?.action
    }

    /// A press spelled the way the combo is, which is what a keyboard
    /// produces for every binding these tests use.
    private func press(_ combo: HerdrKeyCombo) -> HerdrKeyPress {
        HerdrKeyPress(code: combo.code, modifiers: combo.modifiers)
    }

    func testDefaultsCarryHerdrsOwnPrefixAndBindings() {
        let keys = HerdrKeybindings.defaults
        XCTAssertEqual(keys.prefix, HerdrKeyCombo(.character("b"), .control))
        XCTAssertEqual(prefixed(keys, "c"), .newTab)
        XCTAssertEqual(prefixed(keys, "v"), .splitVertical)
        XCTAssertEqual(prefixed(keys, "minus"), .splitHorizontal)
        XCTAssertEqual(prefixed(keys, "z"), .zoom)
        XCTAssertEqual(prefixed(keys, "x"), .closePane)
        XCTAssertEqual(prefixed(keys, "h"), .focusPane(.left))
        XCTAssertEqual(prefixed(keys, "shift+l"), .swapPane(.right))
        XCTAssertEqual(prefixed(keys, "shift+x"), .closeTab)
        XCTAssertEqual(prefixed(keys, "n"), .nextTab)
    }

    func testIndexedDefaultExpandsOverTheNumberRow() {
        let keys = HerdrKeybindings.defaults
        XCTAssertEqual(prefixed(keys, "1"), .switchTab(0))
        XCTAssertEqual(prefixed(keys, "9"), .switchTab(8))
    }

    func testAUserPrefixReplacesTheDefault() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            prefix = "ctrl+a"
            """)
        XCTAssertEqual(keys.prefix, HerdrKeyCombo(.character("a"), .control))
    }

    /// A field the user wrote takes its key and gives up the default one:
    /// herdr never leaves both bound.
    func testAUserBindingReplacesItsDefaultKeyEntirely() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            focus_pane_left = "prefix+left"
            """)
        XCTAssertEqual(prefixed(keys, "left"), .focusPane(.left))
        XCTAssertNil(prefixed(keys, "h"))
    }

    /// A default whose key a user binding already claimed is dropped without
    /// complaint, so the user's spelling of that key is the only one.
    func testAUserBindingBeatsADefaultOnTheSameKey() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            focus_pane_left = "prefix+c"
            """)
        XCTAssertEqual(prefixed(keys, "c"), .focusPane(.left))
    }

    /// Pressing the prefix twice sends a literal prefix key to the program,
    /// so a prefix-mode binding on the prefix key can never fire.
    func testAPrefixModeBindingOnThePrefixKeyIsDropped() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            prefix = "ctrl+a"
            zoom = "prefix+ctrl+a"
            """)
        XCTAssertNil(prefixed(keys, "ctrl+a"))
    }

    /// A direct binding on a bare printable key would eat ordinary typing.
    func testAnUnmodifiedPrintableDirectBindingIsDropped() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            zoom = "z"
            """)
        XCTAssertNil(direct(keys, "z"))
        XCTAssertNil(prefixed(keys, "z"))
    }

    func testAModifiedDirectBindingIsKept() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            next_tab = "ctrl+n"
            """)
        XCTAssertEqual(direct(keys, "ctrl+n"), .nextTab)
        XCTAssertNil(prefixed(keys, "ctrl+n"))
    }

    func testAListBindsEveryKeyInIt() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            next_tab = ["prefix+n", "prefix+right"]
            """)
        XCTAssertEqual(prefixed(keys, "n"), .nextTab)
        XCTAssertEqual(prefixed(keys, "right"), .nextTab)
    }

    /// An unreadable binding leaves the action unbound rather than falling
    /// back to the default key, which is what makes a typo visible.
    func testAnInvalidBindingLeavesItsActionUnbound() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            zoom = "prefix+nonsense"
            """)
        XCTAssertNil(prefixed(keys, "z"))
    }

    func testAnEmptyBindingUnbindsItsAction() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            zoom = ""
            """)
        XCTAssertNil(prefixed(keys, "z"))
    }

    func testFullscreenIsTheOldSpellingOfZoom() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            fullscreen = "prefix+f"
            """)
        XCTAssertEqual(prefixed(keys, "f"), .zoom)
        XCTAssertNil(prefixed(keys, "z"))
    }

    func testCommandBindingsCarryTheirKindAndSummary() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            prefix = "ctrl+a"

            [[keys.command]]
            key = "prefix+C"
            type = "plugin_action"
            command = "m4ttstack.chat.launcher"
            description = "chat launcher"

            [[keys.command]]
            key = "prefix+G"
            command = "git status"
            """)
        XCTAssertEqual(
            prefixed(keys, "C"),
            .command(
                HerdrCommandBinding(
                    command: "m4ttstack.chat.launcher", kind: .pluginAction, summary: "chat launcher"
                )
            )
        )
        XCTAssertEqual(
            prefixed(keys, "G"),
            .command(HerdrCommandBinding(command: "git status", kind: .shell))
        )
    }

    func testACommandWithNoCommandIsDropped() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]

            [[keys.command]]
            key = "prefix+C"
            command = ""
            """)
        XCTAssertNil(prefixed(keys, "C"))
    }

    /// The default help key is a shifted glyph: the resolver retries with the
    /// character the key actually produced, the way herdr does.
    func testAPressResolvesThroughTheCharacterItGenerated() {
        let keys = HerdrKeybindings.defaults
        let press = HerdrKeyPress(
            code: .character("7"), modifiers: [.shift, .option], generatedText: "?"
        )
        XCTAssertEqual(keys.prefixed(matching: press)?.action, .help)
    }

    /// A whole config of the shape this was written for: a replaced prefix,
    /// arrows in place of the vim pane keys, plugin commands on shifted
    /// letters, and sections that have nothing to do with keys.
    func testReadsAConfigOfTheShapeThisWasWrittenFor() {
        let keys = HerdrKeybindings.read(configText: """
            onboarding = false
            [ui]
            show_agent_labels_on_pane_borders = true

            [ui.sidebar.spaces]
            row_gap = 0
            rows = [
              ["state_icon", "workspace", ],
              ["state_text", "branch", "git_status", ],
            ]

            [theme]
            name = "terminal"

            [keys]
            prefix = "ctrl+a"

            focus_pane_left = "prefix+left"
            focus_pane_down = "prefix+down"
            focus_pane_up = "prefix+up"
            focus_pane_right = "prefix+right"

            [[keys.command]]
            key = "prefix+C"
            type = "plugin_action"
            command = "m4ttstack.chat.launcher"
            description = "chat launcher: every feature behind one key"
            """)
        XCTAssertEqual(keys.prefix, HerdrKeyCombo(.character("a"), .control))
        XCTAssertEqual(prefixed(keys, "left"), .focusPane(.left))
        XCTAssertEqual(prefixed(keys, "right"), .focusPane(.right))
        XCTAssertNil(prefixed(keys, "h"), "the vim keys are given up when the arrows take over")
        XCTAssertEqual(prefixed(keys, "c"), .newTab, "an untouched default is still there")
        XCTAssertEqual(prefixed(keys, "v"), .splitVertical)
        XCTAssertEqual(
            prefixed(keys, "C"),
            .command(
                HerdrCommandBinding(
                    command: "m4ttstack.chat.launcher", kind: .pluginAction,
                    summary: "chat launcher: every feature behind one key"
                )
            )
        )
    }

    func testBindingsCarryTheLabelTheConfigSpelled() {
        let keys = HerdrKeybindings.read(configText: """
            [keys]
            zoom = "prefix+shift+f"
            """)
        guard let combo = HerdrKeyCombo.parse("shift+f") else { return XCTFail("combo") }
        XCTAssertEqual(keys.prefixed(matching: press(combo))?.label, "prefix+shift+f")
    }
}
