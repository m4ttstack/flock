import XCTest
@testable import FlockCore

/// The matrix itself: given what detection found, which of the four states
/// the design's settings row is built around. Pure booleans in, one state
/// out -- no filesystem, no herdr, nothing to mock.
final class HerdrMousePatchDecisionTests: XCTestCase {
    private let installPath = "/Users/matt/.local/bin/herdr"
    private let backupPath = "/Users/matt/.local/bin/herdr.pre-mouse-backup"

    private func decide(
        hasVerbs: Bool, hasBackup: Bool, version: String? = "0.9.2",
        isWritable: Bool = true, newerRelease: String? = nil
    ) -> HerdrMousePatchRowState {
        HerdrMousePatchDecision.decide(
            hasVerbs: hasVerbs, hasBackup: hasBackup, version: version,
            isWritable: isWritable,
            installPath: installPath, backupPath: backupPath, newerRelease: newerRelease
        )
    }

    /// The owner's real machine, verified by hand on 2026-09-18: the
    /// installed herdr carries the verbs and a flock backup sits beside it.
    /// This is the single best test in the suite -- if it says anything
    /// other than `.installed`, the detection is wrong.
    func testVerbsWithABackupReadsAsInstalledByFlock() {
        XCTAssertEqual(
            decide(hasVerbs: true, hasBackup: true),
            .installed(backupPath: backupPath)
        )
    }

    /// Upstream having adopted the change looks identical to flock's own
    /// patch except for the missing backup, and that is the one signal that
    /// tells them apart.
    func testVerbsWithNoBackupReadsAsSupportedUpstream() {
        XCTAssertEqual(
            decide(hasVerbs: true, hasBackup: false),
            .supportedByHerdr
        )
    }

    /// A binary that upstream shipped with the verbs, patched over by flock
    /// anyway (a backup happens to sit beside it from an earlier patch of an
    /// older herdr), still reads as flock's install: the verbs plus a backup
    /// is the installed signal regardless of how the verbs got there.
    func testVerbsWithABackupReadsAsInstalledEvenIfVersionOrWritabilityWouldOtherwiseSayNo() {
        XCTAssertEqual(
            decide(hasVerbs: true, hasBackup: true, version: nil, isWritable: false),
            .installed(backupPath: backupPath)
        )
    }

    func testNoVerbsUnwritableInstallReadsAsNotWritableRegardlessOfVersion() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, version: "0.9.2", isWritable: false),
            .notWritable(installPath: installPath)
        )
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, version: nil, isWritable: false),
            .notWritable(installPath: installPath)
        )
    }

    /// Only the versions this build carries a patch for; anything else reports "not
    /// covered" and offers nothing, with no attempt to identify what version
    /// it actually is.
    func testNoVerbsWrongVersionReadsAsUnsupportedVersion() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, version: nil, isWritable: true),
            .unsupportedVersion
        )
    }

    func testAVersionWithNoCatalogueEntryIsUnsupported() {
        XCTAssertEqual(
            HerdrMousePatchDecision.decide(
                hasVerbs: false, hasBackup: false, version: nil, isWritable: true,
                installPath: installPath, backupPath: backupPath
            ),
            .unsupportedVersion
        )
    }

    func testNoVerbsRightVersionWritableReadsAsPatchable() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, version: "0.9.2", isWritable: true),
            .patchable(installPath: installPath, version: "0.9.2")
        )
    }

    /// A stale backup beside an otherwise plain, unpatched binary (herdr
    /// upgraded out from under an old patch) does not turn the row
    /// installed: no verbs means no patch is live, whatever is sitting next
    /// to it.
    func testNoVerbsWithAStaleBackupStillFallsThroughToTheOrdinaryRules() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: true, version: "0.9.2", isWritable: true),
            .patchable(installPath: installPath, version: "0.9.2")
        )
    }

    /// flock's own patch at a revision the catalog has replaced.
    func testFlocksPatchWithANewerRevisionReadsAsOutdated() {
        let state = decide(hasVerbs: true, hasBackup: true, newerRelease: "0.9.2-r2")
        XCTAssertEqual(
            state, .outdated(installPath: installPath, version: "0.9.2", release: "0.9.2-r2", backupPath: backupPath)
        )
        XCTAssertTrue(state.hasFlockPatch)
    }

    /// No backup means the verbs are not flock's, and an update flock cannot
    /// write, or has no catalogued version for, leaves the patch installed.
    func testAnOutdatedPatchNeedsABackupAWritableLocationAndACataloguedVersion() {
        XCTAssertEqual(decide(hasVerbs: true, hasBackup: false, newerRelease: "0.9.2-r2"), .supportedByHerdr)
        XCTAssertEqual(
            decide(hasVerbs: true, hasBackup: true, isWritable: false, newerRelease: "0.9.2-r2"),
            .installed(backupPath: backupPath)
        )
        XCTAssertEqual(
            decide(hasVerbs: true, hasBackup: true, version: nil, newerRelease: "0.9.2-r2"),
            .installed(backupPath: backupPath)
        )
    }

    /// A stock herdr is never outdated: there is no patch on it to replace.
    func testANewerReleaseMeansNothingWithoutTheVerbs() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, newerRelease: "0.9.2-r2"),
            .patchable(installPath: installPath, version: "0.9.2")
        )
    }
}
