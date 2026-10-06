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

    func testIdentityHuesAreSpreadAroundTheWheelInPickOrder() {
        for palette in ThemePalette.builtins {
            let hues = IdentityPalette.colors(for: palette).map(IdentityPalette.hue(of:))
            for i in hues.indices {
                for j in hues.indices where j > i {
                    let apart = IdentityPalette.distance(hues[i], hues[j])
                    XCTAssertGreaterThanOrEqual(apart, 15, "\(palette.id) \(i) and \(j)")
                    if j < 4 {
                        XCTAssertGreaterThanOrEqual(apart, 45, "\(palette.id) first four, \(i) and \(j)")
                    }
                }
            }
        }
    }

    func testHueDistanceWrapsAroundTheWheel() {
        XCTAssertEqual(IdentityPalette.distance(350, 10), 20)
        XCTAssertEqual(IdentityPalette.distance(10, 350), 20)
    }
}
