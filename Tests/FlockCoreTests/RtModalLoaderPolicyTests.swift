import XCTest
@testable import FlockCore

/// The rt modal's loader stays over its pane until the program is up, not
/// merely started: herdr calls a pane busy the moment its process starts,
/// well before an rt-ui program has drawn anything.
final class RtModalLoaderPolicyTests: XCTestCase {
    func testAnUnstartedCommandIsCovered() {
        XCTAssertTrue(RtModalLoaderPolicy.coversPane(started: false, ended: false, programClaimedMouse: false, sinceStart: nil))
    }

    func testAStartedProgramThatHasNotClaimedTheMouseIsStillCovered() {
        XCTAssertTrue(RtModalLoaderPolicy.coversPane(started: true, ended: false, programClaimedMouse: false, sinceStart: 0.5))
    }

    func testAProgramThatClaimedTheMouseIsUncovered() {
        XCTAssertFalse(RtModalLoaderPolicy.coversPane(started: true, ended: false, programClaimedMouse: true, sinceStart: 0.5))
    }

    /// The claim can land before the next busy poll does.
    func testAClaimBeforeTheStartIsSeenUncoversToo() {
        XCTAssertFalse(RtModalLoaderPolicy.coversPane(started: false, ended: false, programClaimedMouse: true, sinceStart: nil))
    }

    func testTheCeilingUncoversAProgramThatNeverClaimsTheMouse() {
        let ceiling = RtModalLoaderPolicy.ceiling
        XCTAssertTrue(RtModalLoaderPolicy.coversPane(started: true, ended: false, programClaimedMouse: false, sinceStart: ceiling - 0.01))
        XCTAssertFalse(RtModalLoaderPolicy.coversPane(started: true, ended: false, programClaimedMouse: false, sinceStart: ceiling))
    }

    func testAnEndedCommandIsUncovered() {
        XCTAssertFalse(RtModalLoaderPolicy.coversPane(started: true, ended: true, programClaimedMouse: false, sinceStart: 0.1))
    }

    /// A shutdown stops an item before the modal goes; one that never
    /// started has only the shell to show.
    func testAnUnstartedItemThatStopsStaysCovered() {
        XCTAssertTrue(RtModalLoaderPolicy.coversPane(started: false, ended: true, programClaimedMouse: false, sinceStart: nil))
    }

    /// An item restored from an earlier run has no start time: it has been
    /// up far longer than any ceiling.
    func testAStartedItemWithNoStartTimeIsUncovered() {
        XCTAssertFalse(RtModalLoaderPolicy.coversPane(started: true, ended: false, programClaimedMouse: false, sinceStart: nil))
    }
}
