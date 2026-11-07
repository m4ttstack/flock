import FlockCore

extension RGB {
    /// This ground under the chrome's one hover wash (`HoverWashFill`).
    func underHoverWash(_ theme: Theme) -> RGB {
        let text = theme.palette.text
        let amount = ChromeMetrics.HoverWash.opacity
        func mix(_ ground: Int, _ wash: Int) -> Int {
            Int((Double(ground) + (Double(wash) - Double(ground)) * amount).rounded())
        }
        return RGB(mix(red, text.red), mix(green, text.green), mix(blue, text.blue))
    }
}

/// The largest per-channel difference between two `#RRGGBB` strings: a
/// blended colour can land a byte either side of the computed one.
func hexChannelDistance(_ a: String, _ b: String) -> Int {
    func channels(_ hex: String) -> [Int] {
        let digits = Array(hex.dropFirst())
        return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0..<$0 + 2]), radix: 16) ?? -999 }
    }
    return zip(channels(a), channels(b)).map { abs($0 - $1) }.max() ?? .max
}

extension Theme {
    /// `panelSurface` as bytes: the ground every anchored panel (chat, rt,
    /// palette-style popovers) paints.
    var panelSurfaceRGB: RGB {
        let isDark = !ChromeRoles.isLight(panelBg: palette.panelBg)
        return palette.terminalGround.mixed(
            with: isDark ? RGB(255, 255, 255) : RGB(0, 0, 0), amount: ChromeMetrics.AnchoredPanel.surfaceLift
        )
    }

    /// The quiet chrome's neutral roles as bytes, for exact pixel samples.
    var roles: ChromeRoles { palette.chromeRoles }
}
