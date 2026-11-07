import XCTest
@testable import FlockCore

final class TerminalColorsTests: XCTestCase {
    private var lightPalettes: [ThemePalette] {
        ThemePalette.builtins.filter { ChromeRoles.isLight(panelBg: $0.panelBg) }
    }

    private var darkPalettes: [ThemePalette] {
        ThemePalette.builtins.filter { !ChromeRoles.isLight(panelBg: $0.panelBg) }
    }

    private func hues(_ palette: ThemePalette) -> [RGB] {
        [palette.red, palette.green, palette.yellow, palette.blue, palette.mauve, palette.teal]
    }

    func testEveryThemeFillsSixteenSlotsOnTheTerminalGround() {
        for palette in ThemePalette.builtins {
            let colors = palette.terminalColors
            XCTAssertEqual(colors.ansi.count, 16, palette.id)
            XCTAssertEqual(colors.background, palette.terminalGround, palette.id)
        }
    }

    func testBrightHuesRepeatTheirNormalShade() {
        for palette in ThemePalette.builtins {
            let ansi = palette.terminalColors.ansi
            XCTAssertEqual(Array(ansi[1...6]), Array(ansi[9...14]), palette.id)
        }
    }

    func testADarkThemeKeepsCatppuccinsMapping() {
        for palette in darkPalettes {
            let colors = palette.terminalColors
            XCTAssertEqual(colors.foreground, palette.text, palette.id)
            XCTAssertEqual(colors.ansi[0], palette.surface1, palette.id)
            XCTAssertEqual(Array(colors.ansi[1...6]), hues(palette), palette.id)
            XCTAssertEqual(colors.ansi[7], palette.subtext0, palette.id)
            XCTAssertEqual(colors.ansi[8], palette.overlay0, palette.id)
            XCTAssertEqual(colors.ansi[15], palette.text, palette.id)
        }
    }

    func testALightThemesTextClearsItsContrastFloors() {
        XCTAssertFalse(lightPalettes.isEmpty)
        for palette in lightPalettes {
            let colors = palette.terminalColors
            let ground = colors.background
            XCTAssertGreaterThanOrEqual(
                colors.foreground.contrastRatio(with: ground), TerminalColors.lightForegroundContrast, "\(palette.id): foreground"
            )
            XCTAssertGreaterThanOrEqual(
                colors.ansi[7].contrastRatio(with: ground), TerminalColors.lightWhiteContrast, "\(palette.id): white"
            )
            for (index, hue) in colors.ansi[1...6].enumerated() {
                XCTAssertGreaterThanOrEqual(
                    hue.contrastRatio(with: ground), TerminalColors.lightHueContrast, "\(palette.id): slot \(index + 1)"
                )
            }
        }
    }

    /// Emphasis written for a dark terminal (bright white) still has to read
    /// as text on a light ground, and black comes from the chrome's ladder.
    func testALightThemeTakesBlackFromTheLadderAndBrightWhiteFromTheForeground() {
        for palette in lightPalettes {
            let colors = palette.terminalColors
            let roles = palette.chromeRoles
            XCTAssertEqual(colors.ansi[0], roles.textStrong, palette.id)
            XCTAssertEqual(colors.ansi[8], roles.textLabel, palette.id)
            XCTAssertEqual(colors.ansi[15], colors.foreground, palette.id)
        }
    }

    /// A hue that already reads on the ground is left exactly as the theme
    /// drew it; only a faint one is darkened.
    func testALightThemeOnlyDarkensHuesThatFallShort() {
        for palette in lightPalettes {
            let ground = palette.terminalGround
            for (original, mapped) in zip(hues(palette), palette.terminalColors.ansi[1...6])
            where original.contrastRatio(with: ground) >= TerminalColors.lightHueContrast {
                XCTAssertEqual(mapped, original, palette.id)
            }
        }
    }
}
