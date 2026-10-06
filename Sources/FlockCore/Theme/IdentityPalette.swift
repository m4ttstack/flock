import Foundation

/// Eight hues that tell workspaces apart, derived per theme. None sits within
/// `statusClearance` degrees of a status hue, because colour in flock already
/// means agent status, and each clears `minimumContrast` on the canvas so the
/// identity square reads as a mark.
public enum IdentityPalette {
    public static let count = 8
    public static let statusClearance = 25.0
    public static let minimumContrast = 3.0

    public static func colors(for palette: ThemePalette) -> [RGB] {
        let statusHues = [palette.yellow, palette.red, palette.teal, palette.green].map(hue(of:))
        let allowed = stride(from: 0.0, to: 360.0, by: 5.0).filter { candidate in
            statusHues.allSatisfy { distance(candidate, $0) >= statusClearance }
        }
        let accent = HSL(palette.accent)
        let darkens = ChromeRoles.isLight(panelBg: palette.panelBg)
        return pick(allowed, awayFrom: statusHues).map { hue in
            legible(
                HSL(hue: hue, saturation: max(accent.saturation, 0.55), lightness: accent.lightness),
                on: palette.chromeRoles.canvas, darkening: darkens
            )
        }
    }

    public static func hue(of rgb: RGB) -> Double { HSL(rgb).hue }

    public static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Greedy farthest-point order: the first hue sits furthest from any
    /// status hue and each next one furthest from those already picked, so
    /// the leading hues, which the first workspaces wear, are already apart.
    private static func pick(_ hues: [Double], awayFrom status: [Double]) -> [Double] {
        func nearest(_ hue: Double, _ others: [Double]) -> Double {
            others.map { distance(hue, $0) }.min() ?? 360
        }
        var picked: [Double] = []
        var remaining = hues
        while picked.count < count, !remaining.isEmpty {
            let best = remaining.max { a, b in
                let keyA = (nearest(a, picked), nearest(a, status), -a)
                let keyB = (nearest(b, picked), nearest(b, status), -b)
                return keyA < keyB
            }!
            picked.append(best)
            remaining.removeAll { $0 == best }
        }
        return picked
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
