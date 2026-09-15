/// One herdr palette (`src/app/state.rs` `impl Palette`), transcribed verbatim
/// from the Rust `Color::Rgb(r, g, b)` literals. herdr's `terminal()` palette
/// follows the host terminal and has no paddock equivalent, so it is absent.
public struct ThemePalette: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let accent: RGB
    public let panelBg: RGB
    public let activeRowBg: RGB
    public let selectionBg: RGB
    public let surface0: RGB
    public let surface1: RGB
    public let surfaceDim: RGB
    public let overlay0: RGB
    public let overlay1: RGB
    public let text: RGB
    public let subtext0: RGB
    public let mauve: RGB
    public let green: RGB
    public let yellow: RGB
    public let red: RGB
    public let blue: RGB
    public let teal: RGB
    public let peach: RGB
    /// Replaces the derived accent-over-chrome blend where a theme has an
    /// approved exact selection color.
    public let selectionOverride: RGB?

    public var chromeRoles: ChromeRoles {
        ChromeRoles.derive(panelBg: panelBg, accent: accent, selectionOverride: selectionOverride)
    }

    public var terminalGround: RGB { ChromeRoles.terminalGround(panelBg: panelBg) }
}

private typealias Triple = (Int, Int, Int)

extension ThemePalette {
    private init(
        id: String, displayName: String,
        accent: Triple, panelBg: Triple, activeRowBg: Triple, selectionBg: Triple,
        surface0: Triple, surface1: Triple, surfaceDim: Triple, overlay0: Triple, overlay1: Triple,
        text: Triple, subtext0: Triple, mauve: Triple, green: Triple, yellow: Triple, red: Triple,
        blue: Triple, teal: Triple, peach: Triple, selectionOverride: RGB? = nil
    ) {
        func rgb(_ t: Triple) -> RGB { RGB(t.0, t.1, t.2) }
        self.id = id
        self.displayName = displayName
        self.accent = rgb(accent)
        self.panelBg = rgb(panelBg)
        self.activeRowBg = rgb(activeRowBg)
        self.selectionBg = rgb(selectionBg)
        self.surface0 = rgb(surface0)
        self.surface1 = rgb(surface1)
        self.surfaceDim = rgb(surfaceDim)
        self.overlay0 = rgb(overlay0)
        self.overlay1 = rgb(overlay1)
        self.text = rgb(text)
        self.subtext0 = rgb(subtext0)
        self.mauve = rgb(mauve)
        self.green = rgb(green)
        self.yellow = rgb(yellow)
        self.red = rgb(red)
        self.blue = rgb(blue)
        self.teal = rgb(teal)
        self.peach = rgb(peach)
        self.selectionOverride = selectionOverride
    }

    /// Catppuccin Mocha, herdr's default.
    public static let catppuccin = ThemePalette(
        id: "catppuccin", displayName: "Catppuccin",
        accent: (137, 180, 250), panelBg: (24, 24, 37), activeRowBg: (30, 30, 46),
        selectionBg: (49, 50, 68), surface0: (49, 50, 68), surface1: (69, 71, 90),
        surfaceDim: (30, 30, 46), overlay0: (108, 112, 134), overlay1: (127, 132, 156),
        text: (205, 214, 244), subtext0: (166, 173, 200), mauve: (203, 166, 247),
        green: (166, 227, 161), yellow: (249, 226, 175), red: (243, 139, 168),
        blue: (137, 180, 250), teal: (148, 226, 213), peach: (250, 179, 135)
    )

    /// Catppuccin Latte, the light Catppuccin flavor.
    public static let catppuccinLatte = ThemePalette(
        id: "catppuccin-latte", displayName: "Catppuccin Latte",
        accent: (30, 102, 245), panelBg: (239, 241, 245), activeRowBg: (230, 233, 239),
        selectionBg: (189, 208, 245), surface0: (204, 208, 218), surface1: (188, 192, 204),
        surfaceDim: (230, 233, 239), overlay0: (156, 160, 176), overlay1: (140, 143, 161),
        text: (76, 79, 105), subtext0: (108, 111, 133), mauve: (136, 57, 239),
        green: (64, 160, 43), yellow: (223, 142, 29), red: (210, 15, 57),
        blue: (30, 102, 245), teal: (23, 146, 153), peach: (254, 100, 11)
    )

    /// Tokyo Night, blue-purple aesthetic. Paddock's default theme.
    public static let tokyoNight = ThemePalette(
        id: "tokyo-night", displayName: "Tokyo Night",
        accent: (122, 162, 247), panelBg: (26, 27, 38), activeRowBg: (35, 38, 54),
        selectionBg: (45, 54, 80), surface0: (36, 40, 59), surface1: (65, 72, 104),
        surfaceDim: (26, 27, 38), overlay0: (86, 95, 137), overlay1: (105, 113, 150),
        text: (192, 202, 245), subtext0: (169, 177, 214), mauve: (187, 154, 247),
        green: (158, 206, 106), yellow: (224, 175, 104), red: (247, 118, 142),
        blue: (122, 162, 247), teal: (125, 207, 255), peach: (255, 158, 100),
        selectionOverride: RGB(0x2B, 0x3A, 0x62)
    )

    /// Tokyo Night Day, the light Tokyo Night style.
    public static let tokyoNightDay = ThemePalette(
        id: "tokyo-night-day", displayName: "Tokyo Night Day",
        accent: (46, 125, 233), panelBg: (225, 226, 231), activeRowBg: (210, 211, 218),
        selectionBg: (182, 202, 231), surface0: (196, 200, 218), surface1: (168, 174, 203),
        surfaceDim: (210, 211, 218), overlay0: (137, 144, 179), overlay1: (104, 112, 154),
        text: (55, 96, 191), subtext0: (97, 114, 176), mauve: (120, 71, 189),
        green: (88, 117, 57), yellow: (140, 108, 62), red: (245, 42, 101),
        blue: (46, 125, 233), teal: (17, 140, 116), peach: (177, 92, 0)
    )

    /// Dracula, purple/pink/green.
    public static let dracula = ThemePalette(
        id: "dracula", displayName: "Dracula",
        accent: (189, 147, 249), panelBg: (40, 42, 54), activeRowBg: (55, 60, 82),
        selectionBg: (70, 63, 93), surface0: (68, 71, 90), surface1: (98, 114, 164),
        surfaceDim: (40, 42, 54), overlay0: (98, 114, 164), overlay1: (130, 140, 180),
        text: (248, 248, 242), subtext0: (210, 210, 220), mauve: (255, 121, 198),
        green: (80, 250, 123), yellow: (241, 250, 140), red: (255, 85, 85),
        blue: (139, 233, 253), teal: (139, 233, 253), peach: (255, 184, 108)
    )

    /// Nord, frosty blue palette.
    public static let nord = ThemePalette(
        id: "nord", displayName: "Nord",
        accent: (136, 192, 208), panelBg: (46, 52, 64), activeRowBg: (67, 76, 94),
        selectionBg: (64, 80, 93), surface0: (59, 66, 82), surface1: (67, 76, 94),
        surfaceDim: (46, 52, 64), overlay0: (76, 86, 106), overlay1: (100, 110, 130),
        text: (236, 239, 244), subtext0: (216, 222, 233), mauve: (180, 142, 173),
        green: (163, 190, 140), yellow: (235, 203, 139), red: (191, 97, 106),
        blue: (129, 161, 193), teal: (143, 188, 187), peach: (208, 135, 112)
    )

    /// Gruvbox Dark, warm retro palette.
    public static let gruvbox = ThemePalette(
        id: "gruvbox", displayName: "Gruvbox",
        accent: (215, 153, 33), panelBg: (40, 40, 40), activeRowBg: (50, 49, 48),
        selectionBg: (75, 63, 39), surface0: (60, 56, 54), surface1: (80, 73, 69),
        surfaceDim: (40, 40, 40), overlay0: (146, 131, 116), overlay1: (168, 153, 132),
        text: (235, 219, 178), subtext0: (213, 196, 161), mauve: (211, 134, 155),
        green: (184, 187, 38), yellow: (250, 189, 47), red: (251, 73, 52),
        blue: (131, 165, 152), teal: (142, 192, 124), peach: (254, 128, 25)
    )

    /// Gruvbox Light, the light retro palette.
    public static let gruvboxLight = ThemePalette(
        id: "gruvbox-light", displayName: "Gruvbox Light",
        accent: (7, 102, 120), panelBg: (251, 241, 199), activeRowBg: (242, 229, 188),
        selectionBg: (235, 219, 178), surface0: (235, 219, 178), surface1: (213, 196, 161),
        surfaceDim: (242, 229, 188), overlay0: (146, 131, 116), overlay1: (124, 111, 100),
        text: (60, 56, 54), subtext0: (80, 73, 69), mauve: (143, 63, 113),
        green: (121, 116, 14), yellow: (181, 118, 20), red: (157, 0, 6),
        blue: (7, 102, 120), teal: (66, 123, 88), peach: (175, 58, 3)
    )

    /// One Dark, Atom's classic dark theme.
    public static let oneDark = ThemePalette(
        id: "one-dark", displayName: "One Dark",
        accent: (97, 175, 239), panelBg: (40, 44, 52), activeRowBg: (49, 54, 64),
        selectionBg: (51, 70, 89), surface0: (44, 49, 58), surface1: (62, 68, 81),
        surfaceDim: (40, 44, 52), overlay0: (92, 99, 112), overlay1: (115, 122, 135),
        text: (171, 178, 191), subtext0: (150, 156, 168), mauve: (198, 120, 221),
        green: (152, 195, 121), yellow: (229, 192, 123), red: (224, 108, 117),
        blue: (97, 175, 239), teal: (86, 182, 194), peach: (209, 154, 102)
    )

    /// One Light, Atom's classic light theme.
    public static let oneLight = ThemePalette(
        id: "one-light", displayName: "One Light",
        accent: (64, 120, 242), panelBg: (250, 250, 250), activeRowBg: (216, 219, 226),
        selectionBg: (205, 219, 248), surface0: (240, 240, 241), surface1: (229, 229, 230),
        surfaceDim: (245, 245, 246), overlay0: (160, 161, 167), overlay1: (104, 107, 119),
        text: (56, 58, 66), subtext0: (104, 107, 119), mauve: (166, 38, 164),
        green: (80, 161, 79), yellow: (193, 132, 1), red: (228, 86, 73),
        blue: (64, 120, 242), teal: (1, 132, 188), peach: (152, 104, 1)
    )

    /// Solarized Dark, Ethan Schoonover's classic.
    public static let solarized = ThemePalette(
        id: "solarized", displayName: "Solarized",
        accent: (38, 139, 210), panelBg: (0, 43, 54), activeRowBg: (22, 75, 87),
        selectionBg: (8, 62, 85), surface0: (7, 54, 66), surface1: (88, 110, 117),
        surfaceDim: (0, 43, 54), overlay0: (88, 110, 117), overlay1: (101, 123, 131),
        text: (147, 161, 161), subtext0: (131, 148, 150), mauve: (211, 54, 130),
        green: (133, 153, 0), yellow: (181, 137, 0), red: (220, 50, 47),
        blue: (38, 139, 210), teal: (42, 161, 152), peach: (203, 75, 22)
    )

    /// Solarized Light, Ethan Schoonover's light variant.
    public static let solarizedLight = ThemePalette(
        id: "solarized-light", displayName: "Solarized Light",
        accent: (38, 139, 210), panelBg: (253, 246, 227), activeRowBg: (238, 232, 213),
        selectionBg: (201, 220, 223), surface0: (238, 232, 213), surface1: (147, 161, 161),
        surfaceDim: (238, 232, 213), overlay0: (147, 161, 161), overlay1: (88, 110, 117),
        text: (101, 123, 131), subtext0: (131, 148, 150), mauve: (211, 54, 130),
        green: (133, 153, 0), yellow: (181, 137, 0), red: (220, 50, 47),
        blue: (38, 139, 210), teal: (42, 161, 152), peach: (203, 75, 22)
    )

    /// Kanagawa, inspired by Katsushika Hokusai.
    public static let kanagawa = ThemePalette(
        id: "kanagawa", displayName: "Kanagawa",
        accent: (126, 156, 216), panelBg: (31, 31, 40), activeRowBg: (54, 54, 70),
        selectionBg: (50, 56, 75), surface0: (42, 42, 55), surface1: (54, 54, 70),
        surfaceDim: (31, 31, 40), overlay0: (114, 113, 105), overlay1: (135, 134, 125),
        text: (220, 215, 186), subtext0: (200, 195, 170), mauve: (149, 127, 184),
        green: (118, 148, 106), yellow: (192, 163, 110), red: (195, 64, 67),
        blue: (126, 156, 216), teal: (127, 180, 202), peach: (255, 160, 102)
    )

    /// Kanagawa Lotus, the light Kanagawa variant.
    public static let kanagawaLotus = ThemePalette(
        id: "kanagawa-lotus", displayName: "Kanagawa Lotus",
        accent: (77, 105, 155), panelBg: (242, 236, 188), activeRowBg: (213, 206, 163),
        selectionBg: (220, 213, 172), surface0: (220, 213, 172), surface1: (201, 203, 209),
        surfaceDim: (213, 206, 163), overlay0: (160, 156, 172), overlay1: (138, 137, 128),
        text: (84, 84, 100), subtext0: (67, 67, 108), mauve: (98, 76, 131),
        green: (111, 137, 78), yellow: (119, 113, 63), red: (200, 64, 83),
        blue: (77, 105, 155), teal: (78, 140, 162), peach: (204, 109, 0)
    )

    /// Rosé Pine, muted and elegant.
    public static let rosePine = ThemePalette(
        id: "rose-pine", displayName: "Rose Pine",
        accent: (196, 167, 231), panelBg: (25, 23, 36), activeRowBg: (38, 35, 58),
        selectionBg: (59, 52, 75), surface0: (31, 29, 46), surface1: (38, 35, 58),
        surfaceDim: (38, 35, 58), overlay0: (110, 106, 134), overlay1: (144, 140, 170),
        text: (224, 222, 244), subtext0: (200, 197, 220), mauve: (196, 167, 231),
        green: (49, 116, 143), yellow: (246, 193, 119), red: (235, 111, 146),
        blue: (49, 116, 143), teal: (156, 207, 216), peach: (234, 154, 151)
    )

    /// Rosé Pine Dawn, the light Rosé Pine variant.
    public static let rosePineDawn = ThemePalette(
        id: "rose-pine-dawn", displayName: "Rose Pine Dawn",
        accent: (144, 122, 169), panelBg: (250, 244, 237), activeRowBg: (227, 217, 207),
        selectionBg: (242, 233, 225), surface0: (242, 233, 225), surface1: (255, 250, 243),
        surfaceDim: (242, 233, 225), overlay0: (152, 147, 165), overlay1: (121, 117, 147),
        text: (70, 66, 97), subtext0: (121, 117, 147), mauve: (144, 122, 169),
        green: (40, 105, 131), yellow: (234, 157, 52), red: (180, 99, 122),
        blue: (40, 105, 131), teal: (86, 148, 159), peach: (215, 130, 126)
    )

    /// Vesper, minimal high-contrast monochrome with peach and mint accents.
    public static let vesper = ThemePalette(
        id: "vesper", displayName: "Vesper",
        accent: (255, 199, 153), panelBg: (26, 26, 26), activeRowBg: (16, 16, 16),
        selectionBg: (35, 35, 35), surface0: (35, 35, 35), surface1: (40, 40, 40),
        surfaceDim: (16, 16, 16), overlay0: (92, 92, 92), overlay1: (126, 126, 126),
        text: (255, 255, 255), subtext0: (160, 160, 160), mauve: (255, 209, 168),
        green: (153, 255, 228), yellow: (255, 199, 153), red: (255, 128, 128),
        blue: (176, 176, 176), teal: (102, 221, 204), peach: (255, 199, 153)
    )

    /// All 17 concrete built-in herdr palettes, in herdr's `THEME_NAMES` order.
    public static let builtins: [ThemePalette] = [
        .catppuccin, .catppuccinLatte, .tokyoNight, .tokyoNightDay, .dracula,
        .nord, .gruvbox, .gruvboxLight, .oneDark, .oneLight, .solarized,
        .solarizedLight, .kanagawa, .kanagawaLotus, .rosePine, .rosePineDawn, .vesper,
    ]

    public static func == (lhs: ThemePalette, rhs: ThemePalette) -> Bool { lhs.id == rhs.id }
}
