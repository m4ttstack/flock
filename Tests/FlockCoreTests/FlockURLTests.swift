import XCTest
@testable import FlockCore

/// The one door an outside program can knock on. Everything that is not
/// exactly a focus request has to be refused rather than guessed at: this
/// parses input from any process on the machine, including a web page the
/// user merely clicked.
final class FlockURLTests: XCTestCase {
    private func parse(_ string: String) -> FlockURL.Request? {
        guard let url = URL(string: string) else { return nil }
        return FlockURL.parse(url)
    }

    func testAFocusRequestCarriesItsPaneID() {
        XCTAssertEqual(parse("flock://focus?pane=w1:p2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    /// herdr pane ids contain a colon, so callers are expected to encode it.
    /// Both forms have to land on the same pane.
    func testAPercentEncodedPaneIDDecodesToTheSameID() {
        XCTAssertEqual(parse("flock://focus?pane=w1%3Ap2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    /// The dev bundle registers its own scheme so two installed copies cannot
    /// fight over one handler, and it answers the same requests.
    func testTheDevSchemeIsAcceptedToo() {
        XCTAssertEqual(parse("flock-dev://focus?pane=w1:p2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    func testTheSchemeIsMatchedCaseInsensitively() {
        XCTAssertEqual(parse("FLOCK://focus?pane=w1:p2"), .focusPane(PaneID(rawValue: "w1:p2")))
    }

    func testAnotherAppsSchemeIsRefused() {
        XCTAssertNil(parse("herdr://focus?pane=w1:p2"))
        XCTAssertNil(parse("https://focus?pane=w1:p2"))
    }

    /// The shape allows more verbs later; today anything but focus is refused
    /// rather than treated as one.
    func testAnUnknownVerbIsRefused() {
        XCTAssertNil(parse("flock://send?pane=w1:p2"))
        XCTAssertNil(parse("flock://?pane=w1:p2"))
    }

    func testAFocusRequestWithNoPaneIsRefused() {
        XCTAssertNil(parse("flock://focus"))
        XCTAssertNil(parse("flock://focus?pane="))
        XCTAssertNil(parse("flock://focus?tab=w1:t1"))
    }
}
