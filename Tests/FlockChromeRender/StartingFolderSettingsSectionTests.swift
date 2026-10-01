import XCTest
@testable import FlockCore

@MainActor
final class StartingFolderSettingsSectionTests: XCTestCase {
    func testACustomFolderIsShownFromHome() {
        let choice = StartingFolderChoice(folder: .custom, customPath: NSHomeDirectory() + "/notes")
        XCTAssertEqual(StartingFolderSettingsSection.customFolderLabel(for: choice), "~/notes")
        XCTAssertEqual(StartingFolderSettingsSection.customFolderLabel(for: StartingFolderChoice(folder: .custom)), "No folder chosen")
    }

    func testMainCheckoutSaysWhereItFallsBack() {
        XCTAssertEqual(StartingFolderSettingsSection.detail(for: StartingFolderChoice(folder: .mainCheckout)), "Home outside a git repo")
    }

    /// A custom folder's path has a row of its own, beside its Change button.
    func testFoldersThatNeedNoExplainingHaveNoDetail() {
        for folder in [StartingFolder.currentPane, .home, .custom] {
            XCTAssertNil(StartingFolderSettingsSection.detail(for: StartingFolderChoice(folder: folder, customPath: "/Users/acme")), "\(folder)")
        }
    }
}
