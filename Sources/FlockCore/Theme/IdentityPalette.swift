import Foundation

/// Eight hues that tell workspaces apart, derived per theme: the whole wheel
/// at 45 degree steps, so no two are near-repeats. Softer than the status
/// colours (`saturation`), so a workspace's wash or name never reads as an
/// agent's status, and each clears `minimumContrast` on the canvas so the
/// identity square reads as a mark.
public enum IdentityPalette {
    public static let count = 8
    public static let minimumContrast = 3.0
    public static let saturation = 0.5

    /// In the order workspaces are assigned them: each next hue as far as it
    /// can be from those before it, so the first four sit 90 degrees apart.
    static let hues: [Double] = [195, 15, 105, 285, 240, 60, 150, 330]

    public static func colors(for palette: ThemePalette) -> [RGB] {
        let accent = HSL(palette.accent)
        let darkens = ChromeRoles.isLight(panelBg: palette.panelBg)
        return hues.map { hue in
            legible(
                HSL(hue: hue, saturation: saturation, lightness: accent.lightness),
                on: palette.chromeRoles.canvas, darkening: darkens
            )
        }
    }

    public static func hue(of rgb: RGB) -> Double { HSL(rgb).hue }

    public static func saturation(of rgb: RGB) -> Double { HSL(rgb).saturation }

    public static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    private static func legible(_ start: HSL, on ground: RGB, darkening: Bool) -> RGB {
        var color = start
        for _ in 0..<50 {
            let rgb = color.rgb
            if rgb.contrastRatio(with: ground) >= minimumContrast { return rgb }
            color.lightness = min(1, max(0, color.lightness + (darkening ? -0.02 : 0.02)))
        }
        return color.rgb
    }
}

struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    init(_ rgb: RGB) {
        let r = Double(rgb.red) / 255, g = Double(rgb.green) / 255, b = Double(rgb.blue) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        lightness = (high + low) / 2
        saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var h: Double
        if delta == 0 { h = 0 }
        else if high == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { h = 60 * ((b - r) / delta + 2) }
        else { h = 60 * ((r - g) / delta + 4) }
        if h < 0 { h += 360 }
        hue = h
    }

    var rgb: RGB {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        func byte(_ v: Double) -> Int { Int(((v + m) * 255).rounded()).clamped(0, 255) }
        return RGB(byte(r), byte(g), byte(b))
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(high, Swift.max(low, self)) }
}
