import AppKit
import FlockCore
import SwiftUI

/// Maps flock's own `Theme` (17 herdr palettes, `Sources/Flock/Theme/Theme.swift`)
/// into the color slots `GhosttyThemeConfig` needs. Lives here, not in
/// `FlockCore`, because it needs `NSColor` to read a `SwiftUI.Color`'s bytes
/// back out; `GhosttyThemeConfig`'s own text generation is pure and pinned by
/// `GhosttyThemeConfigTests` in `FlockCoreTests` against hand-computed
/// colors, not through this mapping.
extension Theme {
    /// A herdr palette has one shade of each hue, not a separate "bright"
    /// one, so every bright ANSI slot reuses its normal counterpart except
    /// black and white, which get the palette's own next neutral step up
    /// (`overlay0`/`text`) the way a real terminal's bright-black/bright-white
    /// usually reads lighter than the normal pair. `black`/`white` themselves
    /// come from `surface1`/`subtext0` rather than `panelBg`/`text` directly:
    /// a herdr palette's `panelBg` is too dark to read as a foreground
    /// "black" glyph and this mirrors Catppuccin's own published ANSI mapping
    /// (Black -> Surface1), the palette family flock's default theme most
    /// resembles in shape. `magenta`/`cyan` come from `mauve`/`teal`, the
    /// closest-hued fields any herdr palette actually defines -- no palette
    /// here has a field named for either ANSI color, so nothing is invented.
    func ghosttyThemeColors() -> GhosttyThemeColors {
        let ansiColors: [Color] = [
            surface1, red, green, yellow, blue, mauve, teal, subtext0,
            overlay0, red, green, yellow, blue, mauve, teal, text,
        ]
        return GhosttyThemeColors(
            background: terminalGround.ghosttyThemeColor,
            foreground: terminalForeground.ghosttyThemeColor,
            ansi: ansiColors.map(\.ghosttyThemeColor)
        )
    }
}

private extension Color {
    /// Rounds rather than truncates: `Theme`'s colors are built from exact
    /// integer bytes (`Double(r) / 255`), so this only guards against
    /// floating-point round-trip error through `NSColor`, not real precision
    /// loss.
    var ghosttyThemeColor: GhosttyThemeColor {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8(clamping: Int((component * 255).rounded()))
        }
        return GhosttyThemeColor(red: byte(red), green: byte(green), blue: byte(blue))
    }
}
