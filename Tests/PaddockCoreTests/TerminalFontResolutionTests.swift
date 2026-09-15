import XCTest
@testable import PaddockCore

final class TerminalFontResolutionTests: XCTestCase {
    func testQuotedFamilyIsRead() {
        let family = TerminalFontResolution.configuredFamily(
            inConfigText: "theme = tokyo-night\nfont-family = \"JetBrainsMono Nerd Font\"\n"
        )
        XCTAssertEqual(family, "JetBrainsMono Nerd Font")
    }

    func testBareFamilyWithSpacesIsRead() {
        XCTAssertEqual(
            TerminalFontResolution.configuredFamily(inConfigText: "font-family = IBM Plex Mono\n"),
            "IBM Plex Mono"
        )
    }

    func testCommentedAssignmentIsNotAFamily() {
        XCTAssertNil(
            TerminalFontResolution.configuredFamily(inConfigText: "# font-family = Comic Mono\n")
        )
    }

    func testAKeyThatMerelyStartsWithFontFamilyIsNotAnAssignment() {
        XCTAssertNil(
            TerminalFontResolution.configuredFamily(inConfigText: "font-family-fallback = Menlo\n")
        )
    }

    func testTheLastAssignmentWins() {
        XCTAssertEqual(
            TerminalFontResolution.configuredFamily(inConfigText: "font-family = Menlo\nfont-family = Iosevka\n"),
            "Iosevka"
        )
    }

    func testAnUnresolvableFamilyFallsBack() {
        let face = TerminalFontResolution.face(configText: "font-family = Nope Mono\n") { _ in false }
        XCTAssertEqual(face, TerminalFontResolution.fallbackFace)
    }

    func testAResolvableFamilyIsUsed() {
        let face = TerminalFontResolution.face(configText: "font-family = Iosevka\n") { $0 == "Iosevka" }
        XCTAssertEqual(face, "Iosevka")
    }

    func testNoConfigFallsBack() {
        XCTAssertEqual(
            TerminalFontResolution.face(configText: nil) { _ in true },
            TerminalFontResolution.fallbackFace
        )
    }
}
