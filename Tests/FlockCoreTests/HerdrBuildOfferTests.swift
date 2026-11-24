import XCTest

@testable import FlockCore

final class HerdrBuildOfferTests: XCTestCase {
    private let stock = HerdrBuildState.stock(installPath: "/p", installed: "0.9.5", newest: "0.9.5-ms.2")
    private let outdated = HerdrBuildState.outdated(installPath: "/p", installed: "0.9.5-ms.1", newest: "0.9.5-ms.2")

    func testOnlyStockAndOutdatedAreOffered() {
        XCTAssertTrue(HerdrBuildOffer.shouldOffer(state: stock, dismissedFor: nil))
        XCTAssertTrue(HerdrBuildOffer.shouldOffer(state: outdated, dismissedFor: nil))
        for state: HerdrBuildState? in [
            nil, .missing(installPath: "/p"), .current(version: "0.9.5-ms.2"), .notWritable(installPath: "/p"),
            .listUnavailable(installed: nil), .checking(installed: nil),
        ] {
            XCTAssertFalse(HerdrBuildOffer.shouldOffer(state: state, dismissedFor: nil))
            XCTAssertFalse(HerdrBuildOffer.hasAction(for: state))
        }
    }

    func testTokenIsTheNewestBuild() {
        XCTAssertEqual(HerdrBuildOffer.dismissalToken(for: stock), "0.9.5-ms.2")
        XCTAssertEqual(HerdrBuildOffer.dismissalToken(for: outdated), "0.9.5-ms.2")
    }

    func testDismissalHoldsUntilANewerBuild() {
        XCTAssertFalse(HerdrBuildOffer.shouldOffer(state: stock, dismissedFor: "0.9.5-ms.2"))
        XCTAssertTrue(HerdrBuildOffer.shouldOffer(state: stock, dismissedFor: "0.9.5-ms.1"))
        XCTAssertTrue(HerdrBuildOffer.hasAction(for: outdated))
    }

    func testBannerText() {
        XCTAssertEqual(HerdrBuildOffer.bannerHeadline(for: stock), "This herdr isn't the mattstack build")
        XCTAssertEqual(HerdrBuildOffer.bannerHeadline(for: outdated), "herdr 0.9.5-ms.2 is available")
        XCTAssertEqual(HerdrBuildOffer.bannerDetail(for: stock), "flock can install it so clicks, scrolling and themes reach your panes.")
        XCTAssertEqual(HerdrBuildOffer.bannerDetail(for: outdated), "flock can update it without closing your panes.")
        XCTAssertEqual(HerdrBuildOffer.bannerActionTitle(for: stock), "Install")
        XCTAssertEqual(HerdrBuildOffer.bannerActionTitle(for: outdated), "Update")
        XCTAssertEqual(HerdrBuildOffer.bannerDismissTitle, "Not now")
    }
}
