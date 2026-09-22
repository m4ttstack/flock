import XCTest
@testable import FlockCore

/// The row's copy never says "upgrade herdr" or implies the maintainers
/// endorsed this; these tests pin the honest phrasing for each state rather
/// than just its shape.
final class HerdrMousePatchCopyTests: XCTestCase {
    private let installPath = NSHomeDirectory() + "/.local/bin/herdr"
    private let backupPath = NSHomeDirectory() + "/.local/bin/herdr.pre-mouse-backup"

    func testSupportedByHerdrOffersNoAction() {
        XCTAssertNil(HerdrMousePatchCopy.actionTitle(for: .supportedByHerdr))
        XCTAssertFalse(HerdrMousePatchCopy.body(for: .supportedByHerdr).contains("flock"))
    }

    func testInstalledOffersRestoringTheOriginalAndSaysWhereItIs() {
        XCTAssertEqual(HerdrMousePatchCopy.actionTitle(for: .installed(backupPath: backupPath)), "Restore Original")
        XCTAssertTrue(
            HerdrMousePatchCopy.body(for: .installed(backupPath: backupPath)).contains("~/.local/bin/herdr.pre-mouse-backup")
        )
    }

    func testPatchableOffersInstall() {
        XCTAssertEqual(HerdrMousePatchCopy.actionTitle(for: .patchable(installPath: installPath)), "Install")
    }

    func testNotWritableOffersNoActionAndNamesThePath() {
        XCTAssertNil(HerdrMousePatchCopy.actionTitle(for: .notWritable(installPath: installPath)))
        XCTAssertTrue(HerdrMousePatchCopy.body(for: .notWritable(installPath: installPath)).contains("~/.local/bin/herdr"))
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

        XCTAssertTrue(confirmation.message.contains("~/.local/bin/herdr"))
        XCTAssertTrue(confirmation.message.contains(HerdrMousePatchVersion.supported))
    }

    func testRestoreConfirmationNamesTheSavedCopy() {
        let confirmation = HerdrMousePatchCopy.revertConfirmation(installPath: installPath)

        XCTAssertTrue(confirmation.message.contains("~/.local/bin/herdr.pre-mouse-backup"))
        XCTAssertEqual(confirmation.confirmButtonTitle, "Restore")
    }

    func testAPathOutsideHomeIsShownInFull() {
        XCTAssertEqual(HerdrMousePatchCopy.displayPath("/opt/homebrew/bin/herdr"), "/opt/homebrew/bin/herdr")
    }
}
