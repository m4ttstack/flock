import XCTest
@testable import FlockCore

final class HerdrConfigTomlTests: XCTestCase {
    func testReadsScalarAndListBindings() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            prefix = "ctrl+a"
            next_tab = ["prefix+n", "prefix+right"]
            """)
        XCTAssertEqual(section.values["prefix"], ["ctrl+a"])
        XCTAssertEqual(section.values["next_tab"], ["prefix+n", "prefix+right"])
    }

    func testIgnoresEverySectionButKeys() {
        let section = HerdrConfigToml.keysSection(in: """
            onboarding = false
            [ui]
            accent = "cyan"
            [keys]
            prefix = "ctrl+a"
            [theme]
            name = "terminal"
            """)
        XCTAssertEqual(section.values, ["prefix": ["ctrl+a"]])
    }

    /// `[keys.indexed]` is a table INSIDE `[keys]`, so its keys must not land
    /// in the keymap as if they were bindings of their own.
    func testASubTableOfKeysEndsTheKeysSection() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            prefix = "ctrl+a"
            [keys.indexed]
            tabs = "cmd"
            """)
        XCTAssertEqual(section.values, ["prefix": ["ctrl+a"]])
    }

    func testCollectsCommandTablesInOrder() {
        let section = HerdrConfigToml.keysSection(in: """
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
        XCTAssertEqual(section.commands.count, 2)
        XCTAssertEqual(section.commands.first?["key"], "prefix+C")
        XCTAssertEqual(section.commands.first?["type"], "plugin_action")
        XCTAssertEqual(section.commands.first?["description"], "chat launcher")
        XCTAssertEqual(section.commands.last?["key"], "prefix+G")
        XCTAssertEqual(section.commands.last?["command"], "git status")
        XCTAssertNil(section.commands.last?["type"])
    }

    func testStripsCommentsButNotHashesInsideStrings() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            # the prefix
            prefix = "ctrl+a"  # trailing note
            goto = "prefix+#"
            """)
        XCTAssertEqual(section.values["prefix"], ["ctrl+a"])
        XCTAssertEqual(section.values["goto"], ["prefix+#"])
    }

    func testReadsLiteralStrings() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            prefix = 'ctrl+a'
            """)
        XCTAssertEqual(section.values["prefix"], ["ctrl+a"])
    }

    /// A multi-line array elsewhere in the file has lines that start with `[`,
    /// which would otherwise read as section headers and silently reopen the
    /// keymap partway through someone else's table.
    func testAMultiLineArrayIsNotMistakenForSectionHeaders() {
        let section = HerdrConfigToml.keysSection(in: """
            [ui.sidebar.spaces]
            rows = [
              ["state_icon", "workspace"],
              ["state_text", "branch"],
            ]

            [keys]
            prefix = "ctrl+a"
            """)
        XCTAssertEqual(section.values, ["prefix": ["ctrl+a"]])
    }

    func testAMultiLineBindingListIsReadWhole() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            next_tab = [
              "prefix+n",
              "prefix+right",
            ]
            """)
        XCTAssertEqual(section.values["next_tab"], ["prefix+n", "prefix+right"])
    }

    func testSkipsValuesItCannotRead() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            prefix = "ctrl+a"
            confirm = true
            delay = 3
            """)
        XCTAssertEqual(section.values, ["prefix": ["ctrl+a"]])
    }

    func testAnEmptyBindingSurvivesAsAnEmptyString() {
        let section = HerdrConfigToml.keysSection(in: """
            [keys]
            zoom = ""
            """)
        XCTAssertEqual(section.values["zoom"], [""])
    }
}
