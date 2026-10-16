import FlockCore
import XCTest

final class HerdrMousePatchCatalogTests: XCTestCase {
    func testEveryEntryHasAReleaseURLAndAFullChecksum() {
        for entry in HerdrMousePatchCatalog.entries {
            XCTAssertEqual(
                entry.url.absoluteString,
                "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(entry.version)/herdr-mouse-patch-\(entry.version)-arm64"
            )
            XCTAssertEqual(entry.sha256.count, 64, entry.version)
            XCTAssertTrue(entry.sha256.allSatisfy { "0123456789abcdef".contains($0) }, entry.version)
        }
    }

    func testVersionsAreUniqueAndRunWithoutGapsFromTheFirst() {
        let versions = HerdrMousePatchCatalog.entries.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count)
        XCTAssertEqual(versions.first, "0.9.1")
        let patches = versions.compactMap { $0.split(separator: ".").last.flatMap { Int($0) } }
        XCTAssertEqual(patches, Array(1...patches.count), "a herdr version between two patched ones has no patch")
    }

    func testLookupFindsOnlyCataloguedVersions() {
        XCTAssertEqual(HerdrMousePatchCatalog.entry(for: "0.9.5")?.version, "0.9.5")
        XCTAssertNil(HerdrMousePatchCatalog.entry(for: "0.9.6"))
        XCTAssertNil(HerdrMousePatchCatalog.entry(for: "0.9.0"))
    }

    func testSupportedVersionsAreTheCatalog() {
        XCTAssertEqual(HerdrMousePatchVersion.supported, HerdrMousePatchCatalog.entries.map(\.version))
    }

    /// A herdr newer than this flock must never be read as an older one.
    func testANewerHerdrIsNotDetectedAsACataloguedVersion() {
        XCTAssertNil(HerdrMousePatchVersion.detect(in: Data("herdr 0.9.6 build".utf8)))
    }
}
