import XCTest
@testable import FlockCore

final class LauncherHintTests: XCTestCase {
    /// The buttons say what they do; a line under them only for a lookup
    /// that found nothing.
    func testAHarnessThatWasFoundGetsNoLine() {
        XCTAssertNil(LauncherHint.text(detected: ["claude"], searched: ["claude", "codex"]))
    }

    /// A launch that resolves nothing must not read as a pane with nothing to
    /// offer: it says the lookup failed.
    func testNothingFoundSaysSoAndNamesWhatItLookedFor() {
        XCTAssertEqual(
            LauncherHint.text(detected: [], searched: ["claude", "codex"]),
            "no agent CLI found on PATH \u{00B7} looked for claude, codex"
        )
    }

    /// A roster with nothing in it at all is a flock build that offers no
    /// harnesses, not a PATH that failed to resolve one, so the line does not
    /// trail off after "looked for".
    func testAnEmptyRosterStillReadsAsASentence() {
        XCTAssertEqual(
            LauncherHint.text(detected: [], searched: []), "no agent CLI found on PATH"
        )
    }
}
