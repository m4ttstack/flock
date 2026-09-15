import XCTest
@testable import PaddockCore

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

        XCTAssertEqual(roles.chrome.hex, "#14151B")
        XCTAssertEqual(roles.rule.hex, "#363948")
        XCTAssertEqual(roles.canvas.hex, "#2E303D")
        XCTAssertEqual(roles.pane.hex, "#191A22")
        XCTAssertEqual(roles.paneBorder.hex, "#50556A")
        XCTAssertEqual(roles.tabRest.hex, "#262835")
        XCTAssertEqual(roles.selection.hex, "#2B3A62")
        XCTAssertEqual(roles.textStrong.hex, "#E6E7EB")
        XCTAssertEqual(roles.textDim.hex, "#D0D2DC")
        XCTAssertEqual(roles.textLabel.hex, "#A3AACB")
        XCTAssertEqual(roles.accent.hex, "#7AA2F7")
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
        }
    }

    func testPaneIsTheTerminalGroundInEveryTheme() {
        for palette in ThemePalette.builtins {
            XCTAssertEqual(palette.chromeRoles.pane, palette.terminalGround, palette.id)
        }
    }

    func testSelectionCarriesEachThemesOwnAccent() {
        let roles = ThemePalette.dracula.chromeRoles
        let expected = roles.chrome.mixed(with: roles.accent, amount: ChromeRoles.selectionAccentAmount)
        XCTAssertEqual(roles.selection, expected)
        XCTAssertNotEqual(roles.selection, roles.chrome)
    }

    func testContrastRatioMatchesTheWCAGExtremes() {
        XCTAssertEqual(RGB(0, 0, 0).contrastRatio(with: RGB(255, 255, 255)), 21, accuracy: 0.001)
        XCTAssertEqual(RGB(20, 21, 27).contrastRatio(with: RGB(20, 21, 27)), 1, accuracy: 0.001)
    }
}
