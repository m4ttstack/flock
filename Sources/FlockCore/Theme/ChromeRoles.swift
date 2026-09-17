import Foundation

/// One sRGB color as whole bytes, free of any UI framework so the chrome
/// derivation and its contrast guarantees stay testable from `FlockCoreTests`.
public struct RGB: Hashable, Sendable, CustomStringConvertible {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    public var description: String { hex }

    var channels: [Int] { [red, green, blue] }

    /// WCAG 2 relative luminance.
    public var relativeLuminance: Double {
        func linear(_ byte: Int) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, symmetric in its two colors.
    public func contrastRatio(with other: RGB) -> Double {
        let (lighter, darker) = relativeLuminance >= other.relativeLuminance
            ? (relativeLuminance, other.relativeLuminance)
            : (other.relativeLuminance, relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func offset(_ delta: (Int, Int, Int)) -> RGB {
        func clampByte(_ v: Int) -> Int { min(255, max(0, v)) }
        return RGB(clampByte(red + delta.0), clampByte(green + delta.1), clampByte(blue + delta.2))
    }

    func mixed(with other: RGB, amount: Double) -> RGB {
        func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * amount).rounded()) }
        return RGB(mix(red, other.red), mix(green, other.green), mix(blue, other.blue))
    }
}

/// The shell chrome palette: every non-terminal color the window paints.
///
/// Dark themes take fixed per-channel offsets from `panelBg`, calibrated so
/// Tokyo Night reproduces the approved hexes exactly. A light `panelBg` has no
/// headroom for those offsets (they would clamp to white), so light themes
/// run the ladder the other way: chrome is lifted slightly above the panel and
/// every darker role is the panel's own color scaled toward black by the same
/// mean step its dark offset takes, which keeps the theme's hue instead of
/// saturating it the way a flat subtraction from a tinted panel would.
public struct ChromeRoles: Equatable, Sendable {
    public let chrome: RGB
    public let rule: RGB
    public let canvas: RGB
    public let pane: RGB
    public let paneBorder: RGB
    public let tabRest: RGB
    public let selection: RGB
    public let textStrong: RGB
    public let textDim: RGB
    public let textLabel: RGB
    public let accent: RGB

    /// The grid's tab handle strip, as one pair. The band has to read against
    /// a thumbnail's `canvas` body, which only `paneBorder` does; the title on
    /// it has to clear AA in every theme, which only `textStrong` does
    /// (`textDim` falls to 4.27:1 on nord). Named here rather than spelled in
    /// the view so the pairing the AA gate checks is the pairing drawn.
    public var tabStripFill: RGB { paneBorder }
    public var tabStripTitle: RGB { textStrong }

    static let chromeOffset = (-6, -6, -11)
    static let ruleOffset = (28, 30, 34)
    static let canvasOffset = (20, 21, 23)
    static let paneBorderOffset = (54, 58, 68)
    static let tabRestOffset = (12, 13, 15)
    static let textStrongOffset = (204, 204, 197)
    static let textDimOffset = (182, 183, 182)
    static let textLabelOffset = (137, 143, 165)

    /// How much of the accent tints chrome to make a selected surface.
    public static let selectionAccentAmount = 0.27
    /// The brightest channel a light theme's lifted chrome may reach, so it
    /// never lands on pure white.
    static let lightChromeCeiling = 250.0

    /// The terminal's own ground, shared with ghostty's background; panes paint
    /// exactly this so the sub-cell remainder around a surface is invisible.
    public static func terminalGround(panelBg: RGB) -> RGB {
        panelBg.offset((-1, -1, -4))
    }

    public static func isLight(panelBg: RGB) -> Bool {
        panelBg.relativeLuminance > 0.5
    }

    public static func derive(panelBg: RGB, accent: RGB, selectionOverride: RGB? = nil) -> ChromeRoles {
        let ladder = isLight(panelBg: panelBg) ? lightLadder(panelBg: panelBg) : darkLadder(panelBg: panelBg)
        return ChromeRoles(
            chrome: ladder.chrome,
            rule: ladder.rule,
            canvas: ladder.canvas,
            pane: terminalGround(panelBg: panelBg),
            paneBorder: ladder.paneBorder,
            tabRest: ladder.tabRest,
            selection: selectionOverride ?? ladder.chrome.mixed(with: accent, amount: selectionAccentAmount),
            textStrong: ladder.textStrong,
            textDim: ladder.textDim,
            textLabel: ladder.textLabel,
            accent: accent
        )
    }

    private struct Ladder {
        let chrome, rule, canvas, paneBorder, tabRest, textStrong, textDim, textLabel: RGB
    }

    private static func darkLadder(panelBg: RGB) -> Ladder {
        Ladder(
            chrome: panelBg.offset(chromeOffset),
            rule: panelBg.offset(ruleOffset),
            canvas: panelBg.offset(canvasOffset),
            paneBorder: panelBg.offset(paneBorderOffset),
            tabRest: panelBg.offset(tabRestOffset),
            textStrong: panelBg.offset(textStrongOffset),
            textDim: panelBg.offset(textDimOffset),
            textLabel: panelBg.offset(textLabelOffset)
        )
    }

    private static func lightLadder(panelBg: RGB) -> Ladder {
        func mean(_ delta: (Int, Int, Int)) -> Double { Double(delta.0 + delta.1 + delta.2) / 3 }
        let lift = -mean(chromeOffset)
        let brightest = Double(panelBg.channels.max() ?? 0)
        let shift = max(0, brightest + lift - lightChromeCeiling)
        let base = panelBg.channels.map { Double($0) - shift }
        let baseMean = base.reduce(0, +) / 3

        func make(_ values: [Double]) -> RGB {
            let bytes = values.map { min(255, max(0, Int($0.rounded()))) }
            return RGB(bytes[0], bytes[1], bytes[2])
        }
        func darkened(by delta: (Int, Int, Int)) -> RGB {
            let factor = (baseMean - mean(delta)) / baseMean
            return make(base.map { $0 * factor })
        }

        return Ladder(
            chrome: make(base.map { $0 + lift }),
            rule: darkened(by: ruleOffset),
            canvas: darkened(by: canvasOffset),
            paneBorder: darkened(by: paneBorderOffset),
            tabRest: darkened(by: tabRestOffset),
            textStrong: darkened(by: textStrongOffset),
            textDim: darkened(by: textDimOffset),
            textLabel: darkened(by: textLabelOffset)
        )
    }
}
