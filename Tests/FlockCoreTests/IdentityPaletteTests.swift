import XCTest
@testable import FlockCore

final class IdentityPaletteTests: XCTestCase {
    func testEveryBuiltinThemeGetsEightLegibleHuesClearOfEveryStatusHue() {
        for palette in ThemePalette.builtins {
            let colors = IdentityPalette.colors(for: palette)
            XCTAssertEqual(colors.count, IdentityPalette.count, palette.id)
            let statusHues = [palette.yellow, palette.red, palette.teal, palette.green].map(IdentityPalette.hue(of:))
            for color in colors {
                let hue = IdentityPalette.hue(of: color)
                for status in statusHues {
                    // One degree of slack for rounding to whole bytes.
                    XCTAssertGreaterThanOrEqual(IdentityPalette.distance(hue, status), IdentityPalette.statusClearance - 1, "\(palette.id) \(color)")
                }
                XCTAssertGreaterThanOrEqual(color.contrastRatio(with: palette.chromeRoles.canvas), IdentityPalette.minimumContrast, "\(palette.id) \(color)")
            }
        }
    }

    func testHueDistanceWrapsAroundTheWheel() {
        XCTAssertEqual(IdentityPalette.distance(350, 10), 20)
        XCTAssertEqual(IdentityPalette.distance(10, 350), 20)
    }
}
