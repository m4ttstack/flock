import Foundation

/// The colors herdr reports to a pane's programs when they ask their terminal
/// (OSC 10/11 and `CSI ? 996 n`), which is how a program set to match its
/// terminal picks light or dark. Sent to the patched herdr as
/// `terminal.host_theme`.
public struct HostTerminalTheme: Equatable, Sendable {
    public var foreground: GhosttyThemeColor
    public var background: GhosttyThemeColor
    public var isLight: Bool

    public init(colors: GhosttyThemeColors) {
        foreground = colors.foreground
        background = colors.background
        // The terminal ground sits a few units off the theme's panel color,
        // too little to cross `isLight`'s threshold for any theme.
        let ground = RGB(Int(colors.background.red), Int(colors.background.green), Int(colors.background.blue))
        isLight = ChromeRoles.isLight(panelBg: ground)
    }

    public var command: [String: Any] {
        [
            "type": ControlBridge.hostThemeCommandType,
            "fg": foreground.hex,
            "bg": background.hex,
            "appearance": isLight ? "light" : "dark",
        ]
    }
}
