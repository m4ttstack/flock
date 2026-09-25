import AppKit
import FlockCore
import SwiftUI

/// A shortcut as macOS writes it in a menu: modifiers in ⌃⌥⇧⌘ order, then the key.
enum ShortcutLabel {
    static func text(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + keyText(key)
    }

    private static func keyText(_ key: KeyEquivalent) -> String {
        switch key {
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .return: return "↩"
        default: break
        }
        if let scalar = key.character.unicodeScalars.first, scalar.value == UInt32(NSF2FunctionKey) { return "F2" }
        return String(key.character).uppercased()
    }
}

/// The right-click toggle, titled for what choosing it will do.
enum RightClickToggle {
    static func title(for mode: RightClickMode?) -> String {
        mode == .program ? "Give Right-Clicks to Flock" : "Send Right-Clicks to Program"
    }
}
