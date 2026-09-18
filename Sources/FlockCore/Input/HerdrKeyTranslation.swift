import Carbon.HIToolbox
import Foundation

/// Turns the four things a macOS key event carries into the key herdr's
/// config would name, decoupled from `NSEvent` so the rule is reachable from
/// `FlockCoreTests` with no AppKit event to build. The app maps an `NSEvent`
/// into these arguments at the call site.
public enum HerdrKeyTranslation {
    public static func press(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: HerdrKeyModifiers
    ) -> HerdrKeyPress? {
        if let code = namedCode(keyCode) {
            return HerdrKeyPress(code: code, modifiers: modifiers, generatedText: characters)
        }
        guard let unmodified = charactersIgnoringModifiers?.first else { return nil }
        // macOS applies Shift to `charactersIgnoringModifiers`, so this one
        // string is both the glyph Shift produced and, lowercased, the key
        // that produced it. That is exactly the pair herdr reads off its own
        // terminal's key report.
        guard let base = unmodified.lowercased().first else { return nil }
        return HerdrKeyPress(
            code: .character(base),
            modifiers: modifiers,
            shiftedCharacter: modifiers.contains(.shift) ? unmodified : nil,
            generatedText: characters
        )
    }

    /// The keys whose characters are control codes or private-use scalars,
    /// which only their key code identifies.
    private static func namedCode(_ keyCode: UInt16) -> HerdrKeyCode? {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: .enter
        case kVK_Escape: .escape
        case kVK_Tab: .tab
        case kVK_Delete: .backspace
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_F1: .function(1)
        case kVK_F2: .function(2)
        case kVK_F3: .function(3)
        case kVK_F4: .function(4)
        case kVK_F5: .function(5)
        case kVK_F6: .function(6)
        case kVK_F7: .function(7)
        case kVK_F8: .function(8)
        case kVK_F9: .function(9)
        case kVK_F10: .function(10)
        case kVK_F11: .function(11)
        case kVK_F12: .function(12)
        default: nil
        }
    }
}
