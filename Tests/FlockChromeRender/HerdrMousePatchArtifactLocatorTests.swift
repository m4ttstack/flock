import Foundation
import XCTest

/// `Bundle.main` in a test host is the xctest runner, never Flock.app, so
/// every case here builds its own throwaway "bundle" (just a directory with a
/// resources subfolder) rather than depending on what happens to be bundled
/// alongside these tests.
final class HerdrMousePatchArtifactLocatorTests: XCTestCase {
    private var root: URL!
    private var resources: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-herdr-mouse-patch-artifact-\(UUID().uuidString)", isDirectory: true)
        resources = root.appendingPathComponent("Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        resources = nil
        super.tearDown()
    }

    private var bundle: Bundle {
        Bundle(url: root)!
    }

    private var expectedName: String {
        HerdrMousePatchArtifactLocator.resourceName(version: "0.9.1")
    }

    func testAbsentArtifactResolvesToNil() {
        XCTAssertNil(HerdrMousePatchArtifactLocator.path(version: "0.9.1", bundle: bundle))
    }

    func testPresentArtifactResolvesToItsPath() throws {
        let artifact = resources.appendingPathComponent(expectedName)
        FileManager.default.createFile(atPath: artifact.path, contents: Data([0x7f, 0x45, 0x4c, 0x46]))

        XCTAssertEqual(HerdrMousePatchArtifactLocator.path(version: "0.9.1", bundle: bundle), artifact.path)
    }

    /// A future version this build was never given an artifact for must not
    /// resolve to some other version's file.
    func testADifferentVersionsArtifactIsNotFoundUnderThisOne() throws {
        let otherVersion = resources.appendingPathComponent(
            HerdrMousePatchArtifactLocator.resourceName(version: "0.10.0")
        )
        FileManager.default.createFile(atPath: otherVersion.path, contents: Data([0x00]))

        XCTAssertNil(HerdrMousePatchArtifactLocator.path(version: "0.9.1", bundle: bundle))
    }
}
