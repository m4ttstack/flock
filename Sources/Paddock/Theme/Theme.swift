import Observation
import PaddockCore
import SwiftUI

/// One herdr palette as SwiftUI colors, plus the chrome roles derived from it
/// (`ChromeRoles`). Views paint chrome through the roles only; the palette's
/// own hues are for status, the terminal's ANSI mapping, and the few accents
/// that must not match a role (the divider handle's hover color, say).
public struct Theme: Identifiable, Equatable, Sendable {
    public let palette: ThemePalette
    public var id: String { palette.id }
    public var displayName: String { palette.displayName }

    public let accent: Color
    public let mauve: Color
    public let green: Color
    public let yellow: Color
    public let red: Color
    public let blue: Color
    public let teal: Color
    public let surface1: Color
    public let surfaceDim: Color
    public let overlay0: Color
    public let text: Color
    public let subtext0: Color

    /// Title bar, sidebar and tab strip: one surface.
    public let chrome: Color
    /// The sidebar's right rule and the rule under the tab strip.
    public let rule: Color
    /// The work surface behind the panes, one step off `chrome`.
    public let canvas: Color
    /// A pane box's ground; always `terminalGround`.
    public let pane: Color
    public let paneBorder: Color
    public let tabRest: Color
    /// The grid's tab handle strip, as one pair: `ChromeRoles` names both so
    /// the AA gate checks the pairing this actually draws.
    public let tabStripFill: Color
    public let tabStripTitle: Color
    /// The selected tab and the selected workspace row.
    public let selection: Color
    public let textStrong: Color
    public let textDim: Color
    /// Headings, counts, resting status dots, the protocol readout and the
    /// resting divider handle.
    public let textLabel: Color

    /// The terminal's own ground and default foreground, handed to ghostty.
    public let terminalGround: Color
    public let terminalForeground: Color

    init(_ palette: ThemePalette) {
        self.palette = palette
        accent = Color(palette.accent)
        mauve = Color(palette.mauve)
        green = Color(palette.green)
        yellow = Color(palette.yellow)
        red = Color(palette.red)
        blue = Color(palette.blue)
        teal = Color(palette.teal)
        surface1 = Color(palette.surface1)
        surfaceDim = Color(palette.surfaceDim)
        overlay0 = Color(palette.overlay0)
        text = Color(palette.text)
        subtext0 = Color(palette.subtext0)

        let roles = palette.chromeRoles
        chrome = Color(roles.chrome)
        rule = Color(roles.rule)
        canvas = Color(roles.canvas)
        pane = Color(roles.pane)
        paneBorder = Color(roles.paneBorder)
        tabRest = Color(roles.tabRest)
        tabStripFill = Color(roles.tabStripFill)
        tabStripTitle = Color(roles.tabStripTitle)
        selection = Color(roles.selection)
        textStrong = Color(roles.textStrong)
        textDim = Color(roles.textDim)
        textLabel = Color(roles.textLabel)

        terminalGround = Color(palette.terminalGround)
        terminalForeground = Color(palette.text)
    }

    public static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    /// Paddock's default theme.
    public static let tokyoNight = Theme(.tokyoNight)

    /// Every built-in herdr palette, in herdr's `THEME_NAMES` order.
    public static let builtins: [Theme] = ThemePalette.builtins.map(Theme.init)
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

/// Holds the active theme, persisted across launches. Injected via the
/// SwiftUI environment (`.environment(themeStore)`); views read it with
/// `@Environment(ThemeStore.self)`.
@MainActor
@Observable
public final class ThemeStore {
    public static let defaultsKey = "paddock.theme"

    public private(set) var active: Theme

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedID = userDefaults.string(forKey: Self.defaultsKey)
        active = Theme.builtins.first { $0.id == storedID } ?? .tokyoNight
    }

    public func select(_ theme: Theme) {
        active = theme
        userDefaults.set(theme.id, forKey: Self.defaultsKey)
    }
}
