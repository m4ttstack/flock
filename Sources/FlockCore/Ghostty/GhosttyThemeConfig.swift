// Portions derived from Herdglass (BSL-1.1), Sources/Herdglass/GhosttyRuntime.swift
// (the scratch-config `command =` workaround) and GhosttyConfig.swift (the
// config-text shape this reads back out of).
import Foundation

/// One color slot in a ghostty config: 0...255 per channel, decoupled from any
/// UI framework's color type so this stays reachable from `FlockCoreTests`
/// with no app host. The call site (`Theme`'s own theme-mapping extension,
/// which needs `NSColor` to read a `SwiftUI.Color` back into bytes) lives in
/// the app target instead.
public struct GhosttyThemeColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb`, the form ghostty's own docs use for `palette = N=#rrggbb`
    /// (bare `rrggbb` parses too, but `#` is unambiguous and self-documenting).
    var hex: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }
}

/// The slots a ghostty config needs to look like one flock theme: the
/// terminal's own background/foreground plus the full 16-slot ANSI palette,
/// in ghostty's `palette = N=...` order (0...7 normal, 8...15 bright).
public struct GhosttyThemeColors: Equatable, Sendable {
    public var background: GhosttyThemeColor
    public var foreground: GhosttyThemeColor
    public var ansi: [GhosttyThemeColor]

    /// Traps a wrong-sized palette at construction (a programmer error, never
    /// user input) rather than letting `configText` silently emit a partial
    /// `palette` block that libghostty would then fill the rest of from its
    /// own defaults.
    public init(background: GhosttyThemeColor, foreground: GhosttyThemeColor, ansi: [GhosttyThemeColor]) {
        precondition(ansi.count == 16, "GhosttyThemeColors needs exactly 16 ANSI slots, got \(ansi.count)")
        self.background = background
        self.foreground = foreground
        self.ansi = ansi
    }
}

public enum GhosttyThemeConfig {
    /// The config text for one theme: `background`, `foreground`, then
    /// `palette = 0=...` through `palette = 15=...`, one line each.
    public static func configText(colors: GhosttyThemeColors) -> String {
        var lines = [
            "background = \(colors.background.hex)",
            "foreground = \(colors.foreground.hex)",
        ]
        for (index, color) in colors.ansi.enumerated() {
            lines.append("palette = \(index)=\(color.hex)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The scratch `.ghostty` file text loaded before a surface is created:
    /// the theme lines above, the font lines, the padding lines, plus the one
    /// line that gets a surface's real command past libghostty's silent drop
    /// of `ghostty_surface_config_s`'s `command`/`env_vars` fields at this
    /// vendored commit (see `GhosttyHost.configureNextSurface`, the call
    /// site). `shell:` is explicit rather than relying on the default, so a
    /// bridge argument containing a colon (a socket path, for instance) is
    /// never read as a `direct:`-style prefix.
    ///
    /// `font-family`/`font-size` are the SAME two lines
    /// `GhosttyHost.updateLiveConfig` pushes for a live text-size change (both
    /// routes go through this one function), so a surface's initial font and
    /// a later resize always agree: one truth, never two config-text builders
    /// to keep in sync. `font-family` takes a bare (unquoted) value: ghostty's
    /// own config-line parser only strips a WRAPPING pair of `"` before
    /// handing the value to `RepeatableString.parseCLI`
    /// (`Vendor/ghostty/src/cli/args.zig`'s `LineIterator.next`), so an
    /// unquoted family name with no embedded `"` round-trips unchanged either
    /// way. `font-size` is ghostty's `f32` (`Config.zig`'s `@"font-size"`):
    /// a whole size is written bare, a fractional one as a plain decimal.
    ///
    /// `window-padding-x/y = 0` overrides libghostty's default 2px grid inset
    /// (`window-padding-x`/`-y` in `src/config/Config.zig`, scaled in
    /// `Surface.zig` and subtracted before every grid lookup in
    /// `renderer/size.zig`). `MouseForwarding` divides the raw view point by
    /// the cell size from origin 0, so any padding would shift the leftmost
    /// and topmost slice of every cell onto the previous one; the pane chrome
    /// already provides the visual inset.
    public static func configText(
        colors: GhosttyThemeColors, commandArgv: [String], fontFamily: String, fontSizePoints: Double,
        optionAsAlt: OptionAsAlt
    ) -> String {
        let command = commandArgv.map(\.shellEscaped).joined(separator: " ")
        return configText(colors: colors)
            + "font-family = \(fontFamily)\n"
            // Named explicitly because a family given only as `font-family`
            // leaves ghostty to synthesize bold by smearing the regular
            // face, which renders a full pixel heavier and softer than the
            // real bold member.
            + "font-family-bold = \(fontFamily)\n"
            + "font-family-italic = \(fontFamily)\n"
            + "font-family-bold-italic = \(fontFamily)\n"
            + "font-size = \(fontSizeText(fontSizePoints))\n"
            + "window-padding-x = 0\n"
            + "window-padding-y = 0\n"
            // This key defaults OFF in libghostty (`OptionAsAlt`'s own `.off`
            // case), so without it Option produces no Alt at all and
            // Option+Backspace reaches a shell as nothing.
            + "macos-option-as-alt = \(optionAsAlt.configValue)\n"
            // A program in the pane is on the far side of a herdr pane flock
            // only mirrors and never gets the host clipboard. Saying it here
            // rather than in the read-clipboard callback is what leaves that
            // callback one kind of caller: libghostty passes it no request
            // kind, and under the `ask` default an OSC 52 read and the user's
            // own paste reach it indistinguishable, while `deny` refuses the
            // read first (`Vendor/ghostty/src/Surface.zig`'s
            // `startClipboardRequest`).
            + "clipboard-read = deny\n"
            + "command = shell:\(command)\n"
    }

    static func fontSizeText(_ points: Double) -> String {
        if points == points.rounded(), let whole = Int(exactly: points.rounded()) {
            return String(whole)
        }
        return String(points)
    }
}

extension String {
    /// Single-quoted for a POSIX shell, doubling any embedded single quote so
    /// the scratch config's `command = shell:...` line survives an argument
    /// with a space or a quote in it (a socket path under a temp directory
    /// with a space, in particular).
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
