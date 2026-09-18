import Foundation

/// One key as herdr's config names it. Mirrors `crossterm::event::KeyCode`
/// narrowed to the cases `herdr/src/config/keybinds.rs` `parse_key_combo`
/// can produce, so a binding string read out of herdr's config resolves to
/// the same key herdr would have resolved it to.
public enum HerdrKeyCode: Hashable, Sendable {
    case character(Character)
    case enter
    case escape
    case tab
    /// Shift+Tab, which herdr folds into its own code and then strips the
    /// Shift modifier from; carrying it as a separate code is what keeps
    /// `shift+tab` and `tab` from comparing equal.
    case backTab
    case backspace
    case left
    case right
    case up
    case down
    case function(UInt8)
}

public struct HerdrKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = HerdrKeyModifiers(rawValue: 1 << 0)
    public static let shift = HerdrKeyModifiers(rawValue: 1 << 1)
    public static let option = HerdrKeyModifiers(rawValue: 1 << 2)
    public static let command = HerdrKeyModifiers(rawValue: 1 << 3)
    public static let hyper = HerdrKeyModifiers(rawValue: 1 << 4)
}

/// A key the user actually pressed.
///
/// `shiftedCharacter` and `generatedText` are what the host reports the key
/// produced once the layout and the modifiers were applied; herdr reads the
/// same two things off its terminal's key report, and a binding on a shifted
/// punctuation key (`prefix+?`) resolves through them rather than through the
/// unshifted code.
public struct HerdrKeyPress: Hashable, Sendable {
    public let code: HerdrKeyCode
    public let modifiers: HerdrKeyModifiers
    public let shiftedCharacter: Character?
    public let generatedText: String?

    public init(
        code: HerdrKeyCode,
        modifiers: HerdrKeyModifiers = [],
        shiftedCharacter: Character? = nil,
        generatedText: String? = nil
    ) {
        let normalized = HerdrKeyCombo.normalize(code: code, modifiers: modifiers)
        self.code = normalized.code
        self.modifiers = normalized.modifiers
        self.shiftedCharacter = shiftedCharacter
        self.generatedText = generatedText
    }
}

/// A key combination as a herdr config spells it, and the rule for whether a
/// press satisfies it.
public struct HerdrKeyCombo: Hashable, Sendable {
    public let code: HerdrKeyCode
    public let modifiers: HerdrKeyModifiers

    public init(_ code: HerdrKeyCode, _ modifiers: HerdrKeyModifiers = []) {
        let normalized = Self.normalize(code: code, modifiers: modifiers)
        self.code = normalized.code
        self.modifiers = normalized.modifiers
    }

    /// Shift never survives as a modifier on a back-tab: herdr folds
    /// `shift+tab` into one code so the two spellings of it compare equal.
    static func normalize(
        code: HerdrKeyCode, modifiers: HerdrKeyModifiers
    ) -> (code: HerdrKeyCode, modifiers: HerdrKeyModifiers) {
        switch code {
        case .tab where modifiers.contains(.shift):
            return (.backTab, modifiers.subtracting(.shift))
        case .backTab:
            return (.backTab, modifiers.subtracting(.shift))
        default:
            return (code, modifiers)
        }
    }

    /// Reads one combo out of a config string (`"ctrl+a"`, `"shift+tab"`,
    /// `"f12"`, `"C"`). `nil` for anything herdr itself would reject, which
    /// is what leaves an invalid binding unbound rather than bound to
    /// something close to what was written.
    public static func parse(_ text: String) -> HerdrKeyCombo? {
        var modifiers = HerdrKeyModifiers()
        var keyToken: String?
        for part in text.split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { return nil }
            if let modifier = modifier(named: token) {
                modifiers.insert(modifier)
            } else if keyToken != nil {
                return nil
            } else {
                keyToken = token
            }
        }
        guard let keyToken else { return nil }
        guard var code = self.code(named: keyToken.lowercased(), modifiers: &modifiers) else { return nil }
        // A lone character token is the key itself, so the uppercase form has
        // to be read before the `f<n>` rule can claim a bare `f`.
        if case .character = code, keyToken.count == 1, let character = keyToken.first {
            if character.isUppercase {
                modifiers.insert(.shift)
                code = .character(Character(character.lowercased()))
            } else {
                code = .character(character)
            }
        }
        return HerdrKeyCombo(code, modifiers)
    }

    private static func modifier(named token: String) -> HerdrKeyModifiers? {
        switch token.lowercased() {
        case "ctrl", "control": .control
        case "shift": .shift
        case "alt", "option", "meta": .option
        case "cmd", "command", "super": .command
        case "hyper": .hyper
        default: nil
        }
    }

    private static func code(named token: String, modifiers: inout HerdrKeyModifiers) -> HerdrKeyCode? {
        switch token {
        case "space", " ": return .character(" ")
        case "enter", "return": return .enter
        case "esc", "escape": return .escape
        case "tab":
            if modifiers.contains(.shift) {
                modifiers.remove(.shift)
                return .backTab
            }
            return .tab
        case "backspace", "bs": return .backspace
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        case "minus": return .character("-")
        case "comma": return .character(",")
        case "period": return .character(".")
        case "slash": return .character("/")
        case "backslash": return .character("\\")
        case "quote": return .character("'")
        case "double_quote", "double-quote": return .character("\"")
        case "semicolon": return .character(";")
        case "colon": return .character(":")
        case "percent": return .character("%")
        case "ampersand": return .character("&")
        case "backtick": return .character("`")
        case "plus": return .character("+")
        default: break
        }
        if token.count == 1, let character = token.first {
            return .character(character)
        }
        guard token.hasPrefix("f"), let number = UInt8(token.dropFirst()) else { return nil }
        return .function(number)
    }

    /// Whether `press` is this combo.
    ///
    /// The second clause is what a binding on a shifted glyph rides on: the
    /// default `prefix+?` names a key no keyboard has unshifted, so the press
    /// arrives as its unshifted key plus Shift, and the character Shift
    /// produced is what has to satisfy the binding.
    public func matches(_ press: HerdrKeyPress) -> Bool {
        if press.modifiers == modifiers, codesMatch(press) {
            return true
        }
        return press.modifiers.contains(.shift)
            && press.modifiers.subtracting(.shift) == modifiers
            && shiftedCharacterSatisfies(press)
    }

    private func codesMatch(_ press: HerdrKeyPress) -> Bool {
        guard case .character(let pressed) = press.code, case .character(let expected) = code else {
            return press.code == code
        }
        if pressed.isASCII, pressed.isLetter, expected.isASCII, expected.isLetter {
            return pressed == expected
                || (press.modifiers.contains(.shift) && modifiers.contains(.shift)
                    && pressed.lowercased() == expected.lowercased())
        }
        return pressed == expected || shiftedCharacterSatisfies(press)
    }

    private func shiftedCharacterSatisfies(_ press: HerdrKeyPress) -> Bool {
        guard case .character(let expected) = code, let shifted = press.shiftedCharacter else { return false }
        return shifted == expected
    }
}
