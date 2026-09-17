// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/Ghostty/TerminalSession.swift
// (`TerminalSession.translate(_ flags: NSEvent.ModifierFlags)`).
import GhosttyKit

/// Modifier keys, decoupled from `NSEvent.ModifierFlags` so the translation
/// into libghostty's own bitmask is reachable from `FlockCoreTests` with no
/// AppKit import. `GhosttySession` (the AppKit glue) maps
/// `NSEvent.ModifierFlags` into this at the call site.
public struct GhosttyKeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = GhosttyKeyModifiers(rawValue: 1 << 0)
    public static let control = GhosttyKeyModifiers(rawValue: 1 << 1)
    public static let option = GhosttyKeyModifiers(rawValue: 1 << 2)
    public static let command = GhosttyKeyModifiers(rawValue: 1 << 3)
    public static let capsLock = GhosttyKeyModifiers(rawValue: 1 << 4)
}

public enum GhosttyKeyMods {
    /// The table `ghostty_surface_key`/`ghostty_surface_mouse_button` etc.
    /// need on every call: one `ghostty_input_mods_e` bit per held key,
    /// combined by plain OR the same way libghostty's own headers document.
    public static func translate(_ flags: GhosttyKeyModifiers) -> ghostty_input_mods_e {
        var raw = UInt32(GHOSTTY_MODS_NONE.rawValue)
        if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { raw |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
        return ghostty_input_mods_e(raw)
    }
}
