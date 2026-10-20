import XCTest

@MainActor
final class FlockClientGuardCopyTests: XCTestCase {
    func testLaunchCopyIsUnchanged() {
        let copy = FlockClientGuard.launchCopy(other: "Flock Dev")
        XCTAssertEqual(copy.message, "Flock Dev is also open on this herdr session")
        XCTAssertEqual(
            copy.detail,
            "Two Flocks on one session fight over its panes: each takes them over and sizes "
                + "them to its own window. Quit Flock Dev to keep working here?"
        )
    }

    func testSwitchCopyNamesTheTargetAndReadsForASwitch() {
        let copy = FlockClientGuard.switchCopy(other: "Flock Dev", target: "acme")
        XCTAssertEqual(copy.message, "Flock Dev is already open on acme")
        XCTAssertEqual(
            copy.detail,
            "Two Flocks on one herdr session fight over pane sizes. Quit Flock Dev to switch, stay where you are, or keep both."
        )
    }
}
