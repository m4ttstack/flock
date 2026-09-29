import XCTest
@testable import FlockCore

/// The marker is read straight out of the binary's bytes, never by running
/// it, so these fixtures are synthetic byte blobs rather than real herdr
/// checkouts.
final class HerdrMouseVerbsTests: XCTestCase {
    func testAbsentWhenTheMarkerIsNowhereInTheBytes() {
        let data = Data("some unrelated binary contents".utf8)

        XCTAssertFalse(HerdrMouseVerbs.present(in: data))
    }

    func testPresentWhenTheCaptureVerbAppears() {
        let data = Data("...terminal.mouse_capture...".utf8)

        XCTAssertTrue(HerdrMouseVerbs.present(in: data))
    }

    /// Stock herdr 0.9.2: it accepts inbound `terminal.mouse` but never
    /// reports capture, so it is not mouse support flock can use.
    func testInboundMouseVerbAloneIsAbsent() {
        let data = Data("terminal.inputterminal.resizeterminal.scrollterminal.mouseterminal.release".utf8)

        XCTAssertFalse(HerdrMouseVerbs.present(in: data))
    }

    func testEmptyDataIsAbsent() {
        XCTAssertFalse(HerdrMouseVerbs.present(in: Data()))
    }
}
