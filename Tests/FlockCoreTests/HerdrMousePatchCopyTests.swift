import XCTest
@testable import FlockCore

/// The row's copy never says "upgrade herdr" or implies the maintainers
/// endorsed this; these tests pin the honest phrasing for each state rather
/// than just its shape.
final class HerdrMousePatchCopyTests: XCTestCase {
    private let installPath = "/Users/matt/.local/bin/herdr"
    private let backupPath = "/Users/matt/.local/bin/herdr.pre-flock-mouse-backup"

    func testSupportedByHerdrOffersNoAction() {
        XCTAssertNil(HerdrMousePatchCopy.actionTitle(for: .supportedByHerdr))
        XCTAssertFalse(HerdrMousePatchCopy.body(for: .supportedByHerdr).contains("flock"))
    }

    func testInstalledOffersRevert() {
        XCTAssertEqual(HerdrMousePatchCopy.actionTitle(for: .installed(backupPath: backupPath)), "Revert")
    }

    func testPatchableOffersInstall() {
        XCTAssertEqual(HerdrMousePatchCopy.actionTitle(for: .patchable(installPath: installPath)), "Install")
    }

    func testNotWritableOffersNoActionAndNamesThePath() {
        XCTAssertNil(HerdrMousePatchCopy.actionTitle(for: .notWritable(installPath: installPath)))
        XCTAssertTrue(HerdrMousePatchCopy.body(for: .notWritable(installPath: installPath)).contains(installPath))
    }

    func testUnsupportedVersionOffersNoActionAndNamesTheSupportedVersion() {
        XCTAssertNil(HerdrMousePatchCopy.actionTitle(for: .unsupportedVersion))
        XCTAssertTrue(HerdrMousePatchCopy.body(for: .unsupportedVersion).contains(HerdrMousePatchVersion.supported))
    }

    func testArtifactUnavailableOffersNoAction() {
        XCTAssertNil(HerdrMousePatchCopy.actionTitle(for: .artifactUnavailable(installPath: installPath)))
    }

    /// The install confirmation is the one line the spec insists on: it must
    /// name the exact path being replaced, every time, never a generic
    /// "install the patch?".
    func testInstallConfirmationNamesTheExactPath() {
        let confirmation = HerdrMousePatchCopy.installConfirmation(installPath: installPath)

        XCTAssertTrue(confirmation.message.contains(installPath))
        XCTAssertTrue(confirmation.message.contains(HerdrMousePatchVersion.supported))
    }
}
