import XCTest
@testable import FlockCore

final class HerdrMousePatchVersionTests: XCTestCase {
    func testParsesHerdrsOwnVersionLine() {
        XCTAssertEqual(HerdrMousePatchVersion.parse(versionOutput: "herdr 0.9.5\n"), "0.9.5")
        XCTAssertEqual(HerdrMousePatchVersion.parse(versionOutput: "herdr 0.10.12"), "0.10.12")
    }

    func testRejectsAnythingNotShapedLikeHerdrsVersionLine() {
        for junk in [
            "", "\n", "herdr", "herdr ", "0.9.5", "herdr v0.9.5", "herdr 0.9.5-beta", "herdr 0.9.", "herdr .9.5",
            "herdr 0..5", "herdr 9", "Herdr 0.9.5", "herdr  0.9.5", "herdr 0.9.5 build", "error: herdr 0.9.5",
            "herdr 0.9.5\nherdr 0.9.6",
        ] {
            XCTAssertNil(HerdrMousePatchVersion.parse(versionOutput: junk), junk)
        }
    }

    func testOnlyCataloguedVersionsAreSupported() {
        XCTAssertEqual(HerdrMousePatchVersion.supportedVersion(fromVersionOutput: "herdr 0.9.5\n"), "0.9.5")
        XCTAssertNil(HerdrMousePatchVersion.supportedVersion(fromVersionOutput: "herdr 0.9.6\n"))
        XCTAssertNil(HerdrMousePatchVersion.supportedVersion(fromVersionOutput: "herdr 0.9.51\n"))
    }

    func testAReaderThatCouldNotRunHerdrIsUnsupported() {
        XCTAssertNil(HerdrMousePatchVersion.supportedVersion(fromVersionOutput: nil))
    }
}
