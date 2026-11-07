import XCTest
@testable import FlockCore

final class ChromeRolesTests: XCTestCase {
    private let lightIDs: Set<String> = [
        "catppuccin-latte", "tokyo-night-day", "gruvbox-light", "one-light",
        "solarized-light", "kanagawa-lotus", "rose-pine-dawn",
    ]

    private func derived(_ roles: ChromeRoles) -> [(String, RGB)] {
        [
            ("chrome", roles.chrome), ("rule", roles.rule), ("canvas", roles.canvas),
            ("paneBorder", roles.paneBorder), ("tabRest", roles.tabRest), ("selection", roles.selection),
            ("textStrong", roles.textStrong), ("textDim", roles.textDim), ("textLabel", roles.textLabel),
        ]
    }

    func testTokyoNightLandsOnTheApprovedHexes() {
        let roles = ThemePalette.tokyoNight.chromeRoles

        XCTAssertEqual(roles.chrome.hex, "#191A22")
        XCTAssertEqual(roles.rule.hex, "#363948")
        XCTAssertEqual(roles.canvas.hex, "#2E303D")
        XCTAssertEqual(roles.pane.hex, "#191A22")
        XCTAssertEqual(roles.paneBorder.hex, "#50556A")
        XCTAssertEqual(roles.tabRest.hex, "#262835")
        XCTAssertEqual(roles.selection.hex, "#2B3A62")
        XCTAssertEqual(roles.textStrong.hex, "#E6E7EB")
        XCTAssertEqual(roles.textDim.hex, "#D2D3D6")
        XCTAssertEqual(roles.textLabel.hex, "#A9ABB5")
        XCTAssertEqual(roles.accent.hex, "#7AA2F7")
        XCTAssertEqual(roles.lift.hex, "#35353D")
        XCTAssertEqual(roles.hair.hex, "#2E2F36")
        XCTAssertEqual(roles.hairFocus.hex, "#5E5F64")
    }

    func testChromeIsTheTerminalGroundInEveryTheme() {
        for palette in ThemePalette.builtins {
            XCTAssertEqual(palette.chromeRoles.chrome, palette.terminalGround, palette.id)
        }
    }

    /// Secondary text sheds most of the panel's tint: each channel sits
    /// nearer the text's own grey than the undesaturated ladder step did.
    func testSecondaryTextIsDesaturated() {
        func spread(_ color: RGB) -> Int { [color.red, color.green, color.blue].max()! - [color.red, color.green, color.blue].min()! }
        let roles = ThemePalette.tokyoNight.chromeRoles
        let rawLabel = ThemePalette.tokyoNight.panelBg.offset(ChromeRoles.textLabelOffset)
        let rawDim = ThemePalette.tokyoNight.panelBg.offset(ChromeRoles.textDimOffset)
        XCTAssertEqual(roles.textLabel, rawLabel.desaturated(by: ChromeRoles.textDesaturation))
        XCTAssertEqual(roles.textDim, rawDim.desaturated(by: ChromeRoles.textDesaturation))
        XCTAssertLessThan(spread(roles.textLabel), spread(rawLabel))
    }

    func testDesaturatedEndsAtGreyAndZeroKeepsTheColor() {
        let color = RGB(122, 162, 247)
        XCTAssertEqual(color.desaturated(by: 0), color)
        let grey = color.desaturated(by: 1)
        XCTAssertEqual(grey.red, grey.green)
        XCTAssertEqual(grey.green, grey.blue)
    }

    /// `lift`, `hair` and `hairFocus` are the terminal ground blended toward
    /// white on a dark theme and toward black on a light one, never toward the
    /// accent, and `hairFocus` always stands further off the ground than `hair`.
    func testNeutralRolesStepOffTheGroundWithoutTheAccent() {
        for palette in ThemePalette.builtins {
            let roles = palette.chromeRoles
            let ground = roles.pane
            let light = lightIDs.contains(palette.id)
            for (name, color) in [("lift", roles.lift), ("hair", roles.hair), ("hairFocus", roles.hairFocus)] {
                XCTAssertNotEqual(color, ground, "\(palette.id).\(name)")
                XCTAssertEqual(
                    color.relativeLuminance < ground.relativeLuminance, light,
                    "\(palette.id).\(name) moves the wrong way off the ground"
                )
            }
            XCTAssertGreaterThan(
                roles.hairFocus.contrastRatio(with: ground), roles.hair.contrastRatio(with: ground),
                "\(palette.id): hairFocus must stand out more than hair"
            )
        }
    }

    func testTheLightThemesAreExactlyTheBrightPanels() {
        let detected = Set(ThemePalette.builtins.filter { ChromeRoles.isLight(panelBg: $0.panelBg) }.map(\.id))
        XCTAssertEqual(detected, lightIDs)
    }

    /// A light panel cannot take the dark offsets: they would clamp chrome to
    /// white and text channels to zero.
    func testLightThemeRolesNeverClampToAByteLimit() {
        for palette in ThemePalette.builtins where lightIDs.contains(palette.id) {
            for (name, color) in derived(palette.chromeRoles) {
                for channel in [color.red, color.green, color.blue] {
                    XCTAssertTrue((1...254).contains(channel), "\(palette.id).\(name) = \(color.hex) clamps")
                }
            }
        }
    }

    func testNoThemeDerivesPureWhiteOrPureBlack() {
        for palette in ThemePalette.builtins {
            for (name, color) in derived(palette.chromeRoles) {
                XCTAssertNotEqual(color, RGB(255, 255, 255), "\(palette.id).\(name)")
                XCTAssertNotEqual(color, RGB(0, 0, 0), "\(palette.id).\(name)")
            }
        }
    }

    func testLightThemesRunTheLadderInverted() {
        for palette in ThemePalette.builtins {
            let roles = palette.chromeRoles
            let chromeIsLighter = roles.chrome.relativeLuminance > roles.canvas.relativeLuminance
            let strongIsLighter = roles.textStrong.relativeLuminance > roles.textLabel.relativeLuminance
            let light = lightIDs.contains(palette.id)
            XCTAssertEqual(chromeIsLighter, light, "\(palette.id): chrome against canvas")
            XCTAssertEqual(strongIsLighter, !light, "\(palette.id): textStrong against textLabel")
            XCTAssertEqual(roles.textDim.relativeLuminance > roles.textLabel.relativeLuminance, !light, "\(palette.id): textDim")
        }
    }

    func testTextKeepsAAContrastInEveryTheme() {
        for palette in ThemePalette.builtins {
            let roles = palette.chromeRoles
            XCTAssertGreaterThanOrEqual(roles.textStrong.contrastRatio(with: roles.selection), 4.5, "\(palette.id): textStrong on selection")
            XCTAssertGreaterThanOrEqual(roles.textLabel.contrastRatio(with: roles.chrome), 4.5, "\(palette.id): textLabel on chrome")
            XCTAssertGreaterThanOrEqual(roles.textDim.contrastRatio(with: roles.tabRest), 4.5, "\(palette.id): textDim on tabRest")
            // The grid's tab handle strip, as the pair the view draws: the
            // band reads against a thumbnail's `canvas` body only as
            // `paneBorder`, and only `textStrong` clears AA on that in every
            // theme, which is why the strip does not dim an unfocused title.
            XCTAssertGreaterThanOrEqual(
                roles.tabStripTitle.contrastRatio(with: roles.tabStripFill), 4.5,
                "\(palette.id): the tab strip's title on its own fill"
            )
        }
    }

    func testPaneIsTheTerminalGroundInEveryTheme() {
        for palette in ThemePalette.builtins {
            XCTAssertEqual(palette.chromeRoles.pane, palette.terminalGround, palette.id)
        }
    }

    /// A tint of chrome toward the theme's own accent: every channel between
    /// the two, nearer chrome than accent, and visibly off chrome.
    func testSelectionIsChromeTintedTowardEachThemesOwnAccent() {
        let derived = ThemePalette.builtins.filter { $0.selectionOverride == nil }
        XCTAssertEqual(derived.count, ThemePalette.builtins.count - 1)
        for palette in derived {
            let roles = palette.chromeRoles
            XCTAssertNotEqual(roles.selection, roles.chrome, palette.id)
            let channels = zip(zip(roles.chrome.channels, roles.accent.channels), roles.selection.channels)
            for ((chrome, accent), selection) in channels {
                XCTAssertTrue((min(chrome, accent)...max(chrome, accent)).contains(selection), "\(palette.id): \(roles.selection.hex) leaves chrome..accent")
                XCTAssertLessThanOrEqual(abs(selection - chrome) * 2, abs(accent - chrome) + 1, "\(palette.id): \(roles.selection.hex) is nearer the accent")
            }
        }
    }

    func testContrastRatioMatchesTheWCAGExtremes() {
        XCTAssertEqual(RGB(0, 0, 0).contrastRatio(with: RGB(255, 255, 255)), 21, accuracy: 0.001)
        XCTAssertEqual(RGB(20, 21, 27).contrastRatio(with: RGB(20, 21, 27)), 1, accuracy: 0.001)
    }
}
