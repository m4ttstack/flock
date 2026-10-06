import XCTest
@testable import FlockCore

final class IdentityPaletteTests: XCTestCase {
    func testEveryBuiltinThemeGetsEightLegibleColours() {
        for palette in ThemePalette.builtins {
            let colors = IdentityPalette.colors(for: palette)
            XCTAssertEqual(colors.count, IdentityPalette.count, palette.id)
            for color in colors {
                XCTAssertGreaterThanOrEqual(color.contrastRatio(with: palette.chromeRoles.canvas), IdentityPalette.minimumContrast, "\(palette.id) \(color)")
            }
        }
    }

    func testTheEightHuesCoverTheWheelWithNoNearRepeats() {
        for palette in ThemePalette.builtins {
            let hues = IdentityPalette.colors(for: palette).map(IdentityPalette.hue(of:))
            for i in hues.indices {
                for j in hues.indices where j > i {
                    let apart = IdentityPalette.distance(hues[i], hues[j])
                    // 45 degrees apart, less what rounding to whole bytes and
                    // the contrast step can move a hue.
                    XCTAssertGreaterThanOrEqual(apart, 35, "\(palette.id) \(i) and \(j)")
                    if j < 4 {
                        XCTAssertGreaterThanOrEqual(apart, 80, "\(palette.id) first four, \(i) and \(j)")
                    }
                }
            }
        }
    }

    func testIdentityColoursAreSofterThanStatusColours() {
        for palette in ThemePalette.builtins {
            for color in IdentityPalette.colors(for: palette) {
                XCTAssertLessThanOrEqual(IdentityPalette.saturation(of: color), IdentityPalette.saturation + 0.02, "\(palette.id) \(color)")
            }
        }
    }

    func testHueDistanceWrapsAroundTheWheel() {
        XCTAssertEqual(IdentityPalette.distance(350, 10), 20)
        XCTAssertEqual(IdentityPalette.distance(10, 350), 20)
    }
}
