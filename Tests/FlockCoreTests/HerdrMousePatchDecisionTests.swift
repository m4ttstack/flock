import XCTest
@testable import FlockCore

/// The matrix itself: given what detection found, which of the four states
/// the design's settings row is built around. Pure booleans in, one state
/// out -- no filesystem, no herdr, nothing to mock.
final class HerdrMousePatchDecisionTests: XCTestCase {
    private let installPath = "/Users/matt/.local/bin/herdr"
    private let backupPath = "/Users/matt/.local/bin/herdr.pre-flock-mouse-backup"

    private func decide(
        hasVerbs: Bool, hasBackup: Bool, versionSupported: Bool = true,
        isWritable: Bool = true, artifactAvailable: Bool = true
    ) -> HerdrMousePatchRowState {
        HerdrMousePatchDecision.decide(
            hasVerbs: hasVerbs, hasBackup: hasBackup, versionSupported: versionSupported,
            isWritable: isWritable, artifactAvailable: artifactAvailable,
            installPath: installPath, backupPath: backupPath
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
            decide(hasVerbs: true, hasBackup: true, versionSupported: false, isWritable: false),
            .installed(backupPath: backupPath)
        )
    }

    func testNoVerbsUnwritableInstallReadsAsNotWritableRegardlessOfVersion() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, versionSupported: true, isWritable: false),
            .notWritable(installPath: installPath)
        )
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, versionSupported: false, isWritable: false),
            .notWritable(installPath: installPath)
        )
    }

    /// Scope for this build is 0.9.1 only; anything else reports "not
    /// covered" and offers nothing, with no attempt to identify what version
    /// it actually is.
    func testNoVerbsWrongVersionReadsAsUnsupportedVersion() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, versionSupported: false, isWritable: true),
            .unsupportedVersion
        )
    }

    /// The gitignored artifact can be absent from a fresh clone; that is a
    /// normal state, not a crash.
    func testNoVerbsRightVersionNoArtifactReadsAsArtifactUnavailable() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, versionSupported: true, artifactAvailable: false),
            .artifactUnavailable(installPath: installPath)
        )
    }

    func testNoVerbsRightVersionWritableWithArtifactReadsAsPatchable() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: false, versionSupported: true, isWritable: true, artifactAvailable: true),
            .patchable(installPath: installPath)
        )
    }

    /// A stale backup beside an otherwise plain, unpatched binary (herdr
    /// upgraded out from under an old patch) does not turn the row
    /// installed: no verbs means no patch is live, whatever is sitting next
    /// to it.
    func testNoVerbsWithAStaleBackupStillFallsThroughToTheOrdinaryRules() {
        XCTAssertEqual(
            decide(hasVerbs: false, hasBackup: true, versionSupported: true, isWritable: true, artifactAvailable: true),
            .patchable(installPath: installPath)
        )
    }
}
