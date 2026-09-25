import XCTest
@testable import FlockCore

final class PaletteMatcherTests: XCTestCase {
    private let glitter = PaletteCommand(id: "rt.glitter", namespace: .rt, name: "glitter", hint: "Review and commit")
    private let split = PaletteCommand(id: "pane.splitright", namespace: .pane, name: "Split Right", shortcut: "⌘D")
    private let mouse = PaletteCommand(id: "mouse.rightclicks", namespace: .mouse, name: "Give Right-Clicks to Flock")

    func testAnEmptyQueryMatchesEverythingWithNothingHighlighted() {
        XCTAssertEqual(PaletteMatcher.match("", against: glitter), .init(score: 0, nameIndices: []))
    }

    func testTheNameMatchesAndReportsWhichCharacters() {
        XCTAssertEqual(PaletteMatcher.match("glitter", against: glitter)?.nameIndices, Array(0..<7))
    }

    /// The namespace is part of what is matched, so typing it narrows the list.
    func testTheNamespaceIsMatchedButNeverHighlighted() {
        XCTAssertEqual(PaletteMatcher.match("rt gl", against: glitter)?.nameIndices, [0, 1])
        XCTAssertEqual(PaletteMatcher.match("rtgl", against: glitter)?.nameIndices, [0, 1])
    }

    func testTheHintFindsARowWithoutHighlightingTheName() {
        let match = PaletteMatcher.match("commit", against: glitter)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.nameIndices, [])
    }

    func testMatchingIgnoresCase() {
        XCTAssertNotNil(PaletteMatcher.match("SPLIT", against: split))
    }

    func testCharactersOutOfOrderDoNotMatch() {
        XCTAssertNil(PaletteMatcher.match("xyz", against: glitter))
        XCTAssertNil(PaletteMatcher.match("tilg", against: glitter))
    }

    /// Consecutive characters and word starts outrank the same letters scattered.
    func testARunOfLettersOutranksTheSameLettersScattered() throws {
        let run = try XCTUnwrap(PaletteMatcher.match("glit", against: glitter))
        let scattered = try XCTUnwrap(PaletteMatcher.match("glit", against: mouse))
        XCTAssertGreaterThan(run.score, scattered.score)
    }
}
