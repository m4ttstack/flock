import Carbon.HIToolbox
import XCTest
@testable import FlockCore

/// What a macOS key event has to become for herdr's own bindings to resolve
/// off it.
final class HerdrKeyTranslationTests: XCTestCase {
    private func press(
        _ keyCode: Int, _ characters: String?, _ unmodified: String?, _ modifiers: HerdrKeyModifiers = []
    ) -> HerdrKeyPress? {
        HerdrKeyTranslation.press(
            keyCode: UInt16(keyCode), characters: characters,
            charactersIgnoringModifiers: unmodified, modifiers: modifiers
        )
    }

    /// Control turns the generated text into a control code; the key is still
    /// the letter, which is what `ctrl+a` has to match.
    func testAControlChordKeepsItsLetter() {
        let press = press(kVK_ANSI_A, "\u{01}", "a", .control)
        XCTAssertEqual(press?.code, .character("a"))
        XCTAssertEqual(press?.modifiers, .control)
    }

    func testAShiftedLetterIsTheLowercaseKeyPlusShift() {
        let press = press(kVK_ANSI_C, "C", "C", .shift)
        XCTAssertEqual(press?.code, .character("c"))
        XCTAssertEqual(press?.modifiers, .shift)
        XCTAssertEqual(press?.shiftedCharacter, "C")
    }

    /// The glyph Shift produced is carried alongside the key, which is what
    /// resolves a binding written as the glyph.
    func testAShiftedPunctuationKeyCarriesTheGlyphItProduced() {
        let press = press(kVK_ANSI_Slash, "?", "?", .shift)
        XCTAssertEqual(press?.shiftedCharacter, "?")
        XCTAssertEqual(press?.generatedText, "?")
    }

    func testTheKeysWhoseCharactersAreNotCharacters() {
        XCTAssertEqual(press(kVK_Tab, "\t", "\t")?.code, .tab)
        XCTAssertEqual(press(kVK_Return, "\r", "\r")?.code, .enter)
        XCTAssertEqual(press(kVK_Escape, "\u{1b}", "\u{1b}")?.code, .escape)
        XCTAssertEqual(press(kVK_Delete, "\u{7f}", "\u{7f}")?.code, .backspace)
        XCTAssertEqual(press(kVK_LeftArrow, "\u{f702}", "\u{f702}")?.code, .left)
        XCTAssertEqual(press(kVK_DownArrow, "\u{f701}", "\u{f701}")?.code, .down)
        XCTAssertEqual(press(kVK_F2, "\u{f705}", "\u{f705}")?.code, .function(2))
    }

    /// Shift+Tab is one key, not Tab carrying a modifier, so both spellings
    /// of the binding reach it.
    func testShiftTabBecomesTheOneCodeHerdrNames() {
        let press = press(kVK_Tab, "\t", "\t", .shift)
        XCTAssertEqual(press?.code, .backTab)
        XCTAssertEqual(press?.modifiers, [])
    }

    func testSpaceIsAnOrdinaryCharacter() {
        XCTAssertEqual(press(kVK_Space, " ", " ")?.code, .character(" "))
    }

    func testAnEventWithNoCharactersIsNotAKey() {
        XCTAssertNil(press(kVK_ANSI_A, nil, nil))
        XCTAssertNil(press(kVK_ANSI_A, "", ""))
    }

    /// The whole point of the translation: the prefix a config names is the
    /// press a keyboard makes.
    func testTheTranslatedPressSatisfiesTheConfiguredPrefix() throws {
        let prefix = try XCTUnwrap(HerdrKeyCombo.parse("ctrl+a"))
        let press = try XCTUnwrap(press(kVK_ANSI_A, "\u{01}", "a", .control))
        XCTAssertTrue(prefix.matches(press))
    }
}
