import Foundation

/// The terminal's own colors for one theme: ground, default foreground and the
/// 16 ANSI slots in ghostty's `palette = N` order (0...7 normal, 8...15 bright).
///
/// A herdr palette has one shade of each hue, so every bright slot reuses its
/// normal counterpart except black and white. Dark themes map black/white to
/// `surface1`/`subtext0` and their bright pair to `overlay0`/`text`, after
/// Catppuccin's published ANSI mapping (Black -> Surface1).
///
/// Light themes cannot use that mapping: `surface1` is a pale tint (lighter
/// than the ground on Rose Pine Dawn), and `text` is sometimes too faint or too
/// saturated to read as body text. There black and bright black come from the
/// chrome's light ladder, the foreground and white are the theme's own hues
/// darkened to fixed contrast floors, and bright white equals the foreground so
/// emphasis written for dark terminals still reads as emphasis.
public struct TerminalColors: Equatable, Sendable {
    public let background: RGB
    public let foreground: RGB
    public let ansi: [RGB]

    static let lightForegroundContrast = 7.5
    static let lightWhiteContrast = 5.0
    static let lightHueContrast = 3.0
    /// Above this HSL saturation a light theme's text reads as a link color,
    /// not body text. Muting it alone still leaves a mid blue at 7.5:1, so it
    /// is also taken to a deeper floor to read as ink.
    static let loudSaturation = 0.45
    static let mutedSaturation = 0.31
    static let mutedForegroundContrast = 9.5

    public init(_ palette: ThemePalette) {
        let ground = palette.terminalGround
        background = ground
        let hues = [palette.red, palette.green, palette.yellow, palette.blue, palette.mauve, palette.teal]

        guard ChromeRoles.isLight(panelBg: palette.panelBg) else {
            foreground = palette.text
            ansi = [palette.surface1] + hues + [palette.subtext0, palette.overlay0] + hues + [palette.text]
            return
        }

        let roles = palette.chromeRoles
        var text = HSL(palette.text)
        var fgFloor = Self.lightForegroundContrast
        if text.saturation > Self.loudSaturation {
            text.saturation = Self.mutedSaturation
            fgFloor = Self.mutedForegroundContrast
        }
        let fg = text.rgb.darkened(toContrast: fgFloor, against: ground)
        let white = palette.subtext0.darkened(toContrast: Self.lightWhiteContrast, against: ground)
        let readableHues = hues.map { $0.darkened(toContrast: Self.lightHueContrast, against: ground) }

        foreground = fg
        ansi = [roles.textStrong] + readableHues + [white, roles.textLabel] + readableHues + [fg]
    }
}

extension ThemePalette {
    public var terminalColors: TerminalColors { TerminalColors(self) }
}

private struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(_ rgb: RGB) {
        let r = Double(rgb.red) / 255, g = Double(rgb.green) / 255, b = Double(rgb.blue) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        lightness = (maxC + minC) / 2
        saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        if delta == 0 {
            hue = 0
        } else if maxC == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
    }

    var rgb: RGB {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ v: Double) -> Int { min(255, max(0, Int(((v + m) * 255).rounded()))) }
        return RGB(byte(r), byte(g), byte(b))
    }

}

private extension RGB {
    /// Lowers HSL lightness in the color's own hue. Assumes a light ground,
    /// where darkening only ever raises contrast.
    func darkened(toContrast floor: Double, against ground: RGB) -> RGB {
        guard contrastRatio(with: ground) < floor else { return self }
        var step = HSL(self)
        while step.rgb.contrastRatio(with: ground) < floor, step.lightness > 0 {
            step.lightness = max(0, step.lightness - 0.005)
        }
        return step.rgb
    }
}
