import XCTest
@testable import FlockCore

final class LauncherHintTests: XCTestCase {
    func testAHarnessThatWasFoundGetsTheUsageHint() {
        XCTAssertEqual(
            LauncherHint.text(detected: ["claude"], searched: ["claude", "codex"]),
            "detected on PATH \u{00B7} click launches in this pane \u{00B7} typing hides these"
        )
    }

    /// The silent half of the defect: a launch that resolves nothing rendered
    /// the same "detected on PATH" hint over an empty button row, which reads
    /// as a pane with nothing to offer rather than as a lookup that failed.
    func testNothingFoundSaysSoAndNamesWhatItLookedFor() {
        XCTAssertEqual(
            LauncherHint.text(detected: [], searched: ["claude", "codex"]),
            "no agent CLI found on PATH \u{00B7} looked for claude, codex"
        )
    }

    func testTheTwoStatesNeverShareCopy() {
        XCTAssertNotEqual(
            LauncherHint.text(detected: ["claude"], searched: ["claude", "codex"]),
            LauncherHint.text(detected: [], searched: ["claude", "codex"])
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
