import FlockCore
import XCTest

final class HerdrMousePatchCatalogTests: XCTestCase {
    private let first = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)

    func testEveryEntryHasAReleaseURLAndAFullChecksum() {
        for arch in HerdrPatchArch.allCases {
            for entry in HerdrMousePatchCatalog.entries(for: arch) {
                XCTAssertEqual(
                    entry.url.absoluteString,
                    "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(entry.releaseName)/herdr-mouse-patch-\(entry.releaseName)-\(arch.rawValue)"
                )
                XCTAssertEqual(entry.sha256.count, 64, entry.version)
                XCTAssertTrue(entry.sha256.allSatisfy { "0123456789abcdef".contains($0) }, entry.version)
            }
        }
    }

    func testEveryVersionCarriesAppleSilicon() {
        var versions: [String] = []
        for release in HerdrMousePatchCatalog.releases where !versions.contains(release.version) {
            versions.append(release.version)
        }
        XCTAssertEqual(HerdrMousePatchCatalog.entries(for: .arm64).map(\.version), versions)
    }

    func testARunningMacOnlySeesItsOwnArchitecture() {
        XCTAssertEqual(HerdrMousePatchCatalog.entries, HerdrMousePatchCatalog.entries(for: .current))
        XCTAssertTrue(HerdrMousePatchCatalog.entries.allSatisfy { $0.arch == .current })
    }

    /// An Intel Mac on a version published only for Apple silicon has no
    /// patch, rather than one it cannot run.
    func testAVersionWithoutAnIntelBuildHasNoIntelEntry() {
        let release = HerdrMousePatchRelease(version: "0.9.9", arm64: first)
        XCTAssertNil(release.entry(for: .x86_64))
        XCTAssertEqual(release.entry(for: .arm64)?.fileName, "herdr-mouse-patch-0.9.9-arm64")
    }

    func testVersionsAreUniqueAndRunWithoutGapsFromTheFirst() {
        let releases = HerdrMousePatchCatalog.releases.map { "\($0.version) r\($0.revision)" }
        XCTAssertEqual(Set(releases).count, releases.count, "a version lists the same revision twice")
        var versions: [String] = []
        for release in HerdrMousePatchCatalog.releases where !versions.contains(release.version) {
            versions.append(release.version)
        }
        XCTAssertEqual(versions.first, "0.9.1")
        let patches = versions.compactMap { $0.split(separator: ".").last.flatMap { Int($0) } }
        XCTAssertEqual(patches, Array(1...patches.count), "a herdr version between two patched ones has no patch")
    }

    func testLookupFindsOnlyCataloguedVersions() {
        XCTAssertEqual(HerdrMousePatchCatalog.entry(for: "0.9.5", arch: .arm64)?.version, "0.9.5")
        XCTAssertNil(HerdrMousePatchCatalog.entry(for: "0.9.6"))
        XCTAssertNil(HerdrMousePatchCatalog.entry(for: "0.9.0"))
    }

    func testSupportedVersionsAreTheCatalog() {
        XCTAssertEqual(HerdrMousePatchVersion.supported, HerdrMousePatchCatalog.entries.map(\.version))
    }

    /// A herdr newer than this flock must never be read as an older one.
    func testANewerHerdrIsNotDetectedAsACataloguedVersion() {
        XCTAssertNil(HerdrMousePatchVersion.supportedVersion(fromVersionOutput: "herdr 0.9.6\n"))
    }

    /// Revision 1 keeps the names its releases were published under; a later
    /// revision has its own release and file names.
    func testALaterRevisionHasItsOwnReleaseAndFileNames() throws {
        let entry = try XCTUnwrap(HerdrMousePatchRelease(version: "0.9.9", revision: 2, arm64: first).entry(for: .arm64))
        XCTAssertEqual(entry.releaseName, "0.9.9-r2")
        XCTAssertEqual(
            entry.url.absoluteString,
            "https://github.com/m4ttstack/flock/releases/download/herdr-patch-0.9.9-r2/herdr-mouse-patch-0.9.9-r2-arm64"
        )
        XCTAssertEqual(HerdrMousePatchRelease(version: "0.9.9", arm64: first).entry(for: .arm64)?.releaseName, "0.9.9")
    }

    /// The newest pinned revision is offered, and a herdr carrying any
    /// earlier one of the same architecture reads as outdated.
    func testTheNewestRevisionIsOfferedAndSupersedesTheEarlierOnes() throws {
        let releases = [
            HerdrMousePatchRelease(version: "0.9.9", arm64: first, x86_64: String(repeating: "c", count: 64)),
            HerdrMousePatchRelease(version: "0.9.9", revision: 2, arm64: second),
        ]
        let entry = try XCTUnwrap(HerdrMousePatchCatalog.entry(for: "0.9.9", arch: .arm64, in: releases))
        XCTAssertEqual(entry.revision, 2)
        XCTAssertEqual(entry.sha256, second)
        XCTAssertTrue(entry.supersedes(sha256: first))
        XCTAssertFalse(entry.supersedes(sha256: second))
        XCTAssertFalse(entry.supersedes(sha256: String(repeating: "c", count: 64)), "an Intel build never supersedes on arm64")
        XCTAssertFalse(entry.supersedes(sha256: nil))
        XCTAssertEqual(HerdrMousePatchCatalog.entries(for: .arm64, in: releases).map(\.revision), [2])
    }

    /// A revision whose build is not published yet changes nothing: the
    /// previous revision stays the one offered, and nothing is outdated.
    func testARevisionAwaitingPublicationLeavesThePreviousOneOffered() throws {
        let releases = [
            HerdrMousePatchRelease(version: "0.9.9", arm64: first, x86_64: second),
            HerdrMousePatchRelease(
                version: "0.9.9", revision: 2,
                arm64: HerdrMousePatchCatalog.awaitingPublication, x86_64: HerdrMousePatchCatalog.awaitingPublication
            ),
        ]
        for arch in HerdrPatchArch.allCases {
            let entry = try XCTUnwrap(HerdrMousePatchCatalog.entry(for: "0.9.9", arch: arch, in: releases))
            XCTAssertEqual(entry.revision, 1, arch.rawValue)
            XCTAssertTrue(entry.superseded.isEmpty, arch.rawValue)
        }
    }

    /// An architecture whose newer revision is published only elsewhere
    /// keeps its own latest build.
    func testEachArchitectureTakesItsOwnNewestRevision() throws {
        let releases = [
            HerdrMousePatchRelease(version: "0.9.9", arm64: first, x86_64: second),
            HerdrMousePatchRelease(version: "0.9.9", revision: 2, arm64: String(repeating: "d", count: 64)),
        ]
        XCTAssertEqual(HerdrMousePatchCatalog.entry(for: "0.9.9", arch: .arm64, in: releases)?.revision, 2)
        let intel = try XCTUnwrap(HerdrMousePatchCatalog.entry(for: "0.9.9", arch: .x86_64, in: releases))
        XCTAssertEqual(intel.revision, 1)
        XCTAssertEqual(intel.sha256, second)
    }
}
