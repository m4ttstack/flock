import FlockCore
import XCTest

final class HerdrUpdateTests: XCTestCase {
    func testVersionOrderIsNumericPerComponent() {
        XCTAssertEqual(HerdrVersionOrder.isNewer("0.9.10", than: "0.9.9"), true)
        XCTAssertEqual(HerdrVersionOrder.isNewer("0.9.5", than: "0.9.5"), false)
        XCTAssertEqual(HerdrVersionOrder.isNewer("0.9.4", than: "0.9.5"), false)
        XCTAssertEqual(HerdrVersionOrder.isNewer("1.0", than: "0.9.5"), true)
        XCTAssertNil(HerdrVersionOrder.isNewer("0.9.x", than: "0.9.5"))
    }

    func testTheManifestVersionIsRead() {
        XCTAssertEqual(HerdrLatestManifest.version(from: Data(#"{"version":"0.9.6","releases":{}}"#.utf8)), "0.9.6")
        XCTAssertNil(HerdrLatestManifest.version(from: Data("<html>".utf8)))
        XCTAssertNil(HerdrLatestManifest.version(from: Data(#"{"tag":"v0.9.6"}"#.utf8)))
    }

    func testHomebrewIsACellarPath() {
        XCTAssertTrue(HerdrInstallKind.isHomebrew(resolvedPath: "/opt/homebrew/Cellar/herdr/0.9.5/bin/herdr"))
        XCTAssertFalse(HerdrInstallKind.isHomebrew(resolvedPath: "/Users/acme/.local/bin/herdr"))
    }

    private func decide(
        installed: String? = "0.9.5", latest: String? = "0.9.6", patchInstalled: Bool = false,
        catalogHasLatest: Bool = false, homebrew: Bool = false
    ) -> HerdrUpdateNotice? {
        HerdrUpdateNotice.decide(
            installed: installed, latest: latest, patchInstalled: patchInstalled,
            catalogHasLatest: catalogHasLatest, homebrew: homebrew
        )
    }

    func testNothingShowsWithoutANewerStableVersion() {
        XCTAssertNil(decide(latest: nil))
        XCTAssertNil(decide(installed: nil))
        XCTAssertNil(decide(latest: "0.9.5"))
        XCTAssertNil(decide(installed: "0.9.7", latest: "0.9.6"), "a preview build ahead of stable")
    }

    func testWithoutThePatchItIsAPlainNote() {
        XCTAssertEqual(
            decide(),
            .available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: false)
        )
    }

    func testWithThePatchAndACataloguedLatestItSaysToReinstall() {
        XCTAssertEqual(
            decide(patchInstalled: true, catalogHasLatest: true),
            .available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: true)
        )
    }

    func testWithThePatchAndNoCataloguedLatestItWarns() {
        XCTAssertEqual(
            decide(patchInstalled: true, catalogHasLatest: false),
            .breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff")
        )
    }

    func testHomebrewGetsBrewUpgrade() {
        XCTAssertEqual(
            decide(patchInstalled: true, homebrew: true),
            .breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "brew upgrade herdr")
        )
    }

    func testTheWarningSaysMouseSupportTurnsOff() {
        let notice = HerdrUpdateNotice.breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff")
        XCTAssertEqual(HerdrUpdateCopy.headline(notice), "Updating herdr to 0.9.6 will turn off mouse support in flock")
        XCTAssertEqual(
            HerdrUpdateCopy.detail(notice),
            "flock doesn't have a mouse patch for 0.9.6 yet. Mouse clicks and scrolling in panes stop working until a flock update adds one."
        )
        XCTAssertEqual(HerdrUpdateCopy.pillTitle(notice), "herdr 0.9.6")
    }

    func testThePlainNoteCopy() {
        let reinstall = HerdrUpdateNotice.available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: true)
        XCTAssertEqual(HerdrUpdateCopy.headline(reinstall), "herdr 0.9.6 is available (you have 0.9.5)")
        XCTAssertEqual(HerdrUpdateCopy.detail(reinstall), "Updating removes the mouse patch; reinstall it here afterwards.")
        let plain = HerdrUpdateNotice.available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: false)
        XCTAssertNil(HerdrUpdateCopy.detail(plain))
    }
}
