import FlockCore

/// Maps flock's own `Theme` into the color slots `GhosttyThemeConfig` needs.
/// The slot choices live in `TerminalColors` so they stay testable from
/// `FlockCoreTests`.
extension Theme {
    func ghosttyThemeColors() -> GhosttyThemeColors {
        let terminal = palette.terminalColors
        return GhosttyThemeColors(
            background: terminal.background.ghosttyThemeColor,
            foreground: terminal.foreground.ghosttyThemeColor,
            ansi: terminal.ansi.map(\.ghosttyThemeColor)
        )
    }
}

private extension RGB {
    var ghosttyThemeColor: GhosttyThemeColor {
        GhosttyThemeColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
    }
}
