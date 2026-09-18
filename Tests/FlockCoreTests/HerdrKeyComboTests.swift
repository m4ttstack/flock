import XCTest
@testable import FlockCore

/// Pins the parse and the match against herdr's own
/// `src/config/keybinds.rs` (`parse_key_combo`, `normalize_key_combo`,
/// `key_parts_match_combo`), which is what decides whether a key the user
/// pressed is the key their config named.
final class HerdrKeyComboTests: XCTestCase {
    func testParsesAModifiedLetter() {
        XCTAssertEqual(HerdrKeyCombo.parse("ctrl+a"), HerdrKeyCombo(.character("a"), .control))
    }

    func testParsesModifierAliases() {
        XCTAssertEqual(HerdrKeyCombo.parse("control+x"), HerdrKeyCombo(.character("x"), .control))
        XCTAssertEqual(HerdrKeyCombo.parse("alt+x"), HerdrKeyCombo(.character("x"), .option))
        XCTAssertEqual(HerdrKeyCombo.parse("option+x"), HerdrKeyCombo(.character("x"), .option))
        XCTAssertEqual(HerdrKeyCombo.parse("meta+x"), HerdrKeyCombo(.character("x"), .option))
        XCTAssertEqual(HerdrKeyCombo.parse("cmd+x"), HerdrKeyCombo(.character("x"), .command))
        XCTAssertEqual(HerdrKeyCombo.parse("command+x"), HerdrKeyCombo(.character("x"), .command))
        XCTAssertEqual(HerdrKeyCombo.parse("super+x"), HerdrKeyCombo(.character("x"), .command))
        XCTAssertEqual(HerdrKeyCombo.parse("hyper+x"), HerdrKeyCombo(.character("x"), .hyper))
    }

    /// An uppercase letter is a letter plus Shift, never its own key.
    func testAnUppercaseLetterCarriesShift() {
        XCTAssertEqual(HerdrKeyCombo.parse("C"), HerdrKeyCombo(.character("c"), .shift))
        XCTAssertEqual(HerdrKeyCombo.parse("shift+c"), HerdrKeyCombo(.character("c"), .shift))
    }

    func testParsesNamedKeys() {
        XCTAssertEqual(HerdrKeyCombo.parse("space"), HerdrKeyCombo(.character(" ")))
        XCTAssertEqual(HerdrKeyCombo.parse("enter"), HerdrKeyCombo(.enter))
        XCTAssertEqual(HerdrKeyCombo.parse("return"), HerdrKeyCombo(.enter))
        XCTAssertEqual(HerdrKeyCombo.parse("esc"), HerdrKeyCombo(.escape))
        XCTAssertEqual(HerdrKeyCombo.parse("escape"), HerdrKeyCombo(.escape))
        XCTAssertEqual(HerdrKeyCombo.parse("backspace"), HerdrKeyCombo(.backspace))
        XCTAssertEqual(HerdrKeyCombo.parse("bs"), HerdrKeyCombo(.backspace))
        XCTAssertEqual(HerdrKeyCombo.parse("left"), HerdrKeyCombo(.left))
        XCTAssertEqual(HerdrKeyCombo.parse("ctrl+down"), HerdrKeyCombo(.down, .control))
    }

    func testParsesPunctuationNames() {
        XCTAssertEqual(HerdrKeyCombo.parse("minus"), HerdrKeyCombo(.character("-")))
        XCTAssertEqual(HerdrKeyCombo.parse("comma"), HerdrKeyCombo(.character(",")))
        XCTAssertEqual(HerdrKeyCombo.parse("period"), HerdrKeyCombo(.character(".")))
        XCTAssertEqual(HerdrKeyCombo.parse("slash"), HerdrKeyCombo(.character("/")))
        XCTAssertEqual(HerdrKeyCombo.parse("backslash"), HerdrKeyCombo(.character("\\")))
        XCTAssertEqual(HerdrKeyCombo.parse("semicolon"), HerdrKeyCombo(.character(";")))
        XCTAssertEqual(HerdrKeyCombo.parse("backtick"), HerdrKeyCombo(.character("`")))
        XCTAssertEqual(HerdrKeyCombo.parse("["), HerdrKeyCombo(.character("[")))
    }

    /// A single `f` is the letter; only `f` followed by digits is a function
    /// key, because herdr tries the single-character case first.
    func testFunctionKeysDoNotSwallowTheLetterF() {
        XCTAssertEqual(HerdrKeyCombo.parse("f"), HerdrKeyCombo(.character("f")))
        XCTAssertEqual(HerdrKeyCombo.parse("f12"), HerdrKeyCombo(.function(12)))
        XCTAssertNil(HerdrKeyCombo.parse("fnord"))
    }

    func testShiftTabIsOneCodeWithNoShiftLeftOnIt() {
        XCTAssertEqual(HerdrKeyCombo.parse("shift+tab"), HerdrKeyCombo(.backTab))
        XCTAssertEqual(HerdrKeyCombo.parse("tab"), HerdrKeyCombo(.tab))
        XCTAssertNotEqual(HerdrKeyCombo.parse("shift+tab"), HerdrKeyCombo.parse("tab"))
    }

    func testRejectsMalformedCombos() {
        XCTAssertNil(HerdrKeyCombo.parse(""))
        XCTAssertNil(HerdrKeyCombo.parse("ctrl+"))
        XCTAssertNil(HerdrKeyCombo.parse("ctrl+a+b"))
        XCTAssertNil(HerdrKeyCombo.parse("ctrl"))
    }

    /// `prefix+` is the binding grammar's own token, not a modifier, so a
    /// bare combo parse must refuse it rather than quietly bind the word.
    func testPrefixIsNotAModifier() {
        XCTAssertNil(HerdrKeyCombo.parse("prefix+t"))
    }

    func testMatchesAnExactPress() {
        let combo = HerdrKeyCombo(.character("a"), .control)
        XCTAssertTrue(combo.matches(HerdrKeyPress(code: .character("a"), modifiers: .control)))
        XCTAssertFalse(combo.matches(HerdrKeyPress(code: .character("a"))))
        XCTAssertFalse(combo.matches(HerdrKeyPress(code: .character("b"), modifiers: .control)))
    }

    /// `prefix+C` binds the shifted letter, so an unshifted `c` must not run
    /// it and the shifted one must.
    func testShiftedLetterBindingNeedsShift() throws {
        let combo = try XCTUnwrap(HerdrKeyCombo.parse("C"))
        XCTAssertTrue(combo.matches(HerdrKeyPress(code: .character("c"), modifiers: .shift)))
        XCTAssertFalse(combo.matches(HerdrKeyPress(code: .character("c"))))
    }

    /// The default help binding is `prefix+?`, which no keyboard has as an
    /// unshifted key: the press arrives carrying Shift, and the shifted
    /// character is what satisfies the binding.
    func testAShiftedPunctuationPressSatisfiesItsUnshiftedBinding() throws {
        let combo = try XCTUnwrap(HerdrKeyCombo.parse("?"))
        let press = HerdrKeyPress(code: .character("/"), modifiers: .shift, shiftedCharacter: "?")
        XCTAssertTrue(combo.matches(press))
    }

    func testAShiftedPressDoesNotSatisfyAnUnrelatedBinding() throws {
        let combo = try XCTUnwrap(HerdrKeyCombo.parse("1"))
        let press = HerdrKeyPress(code: .character("1"), modifiers: .shift, shiftedCharacter: "!")
        XCTAssertFalse(combo.matches(press))
    }

    func testBothSpellingsOfShiftTabMatchTheSamePress() throws {
        let combo = try XCTUnwrap(HerdrKeyCombo.parse("shift+tab"))
        XCTAssertTrue(combo.matches(HerdrKeyPress(code: .tab, modifiers: .shift)))
        XCTAssertTrue(combo.matches(HerdrKeyPress(code: .backTab)))
        XCTAssertFalse(combo.matches(HerdrKeyPress(code: .tab)))
    }
}
