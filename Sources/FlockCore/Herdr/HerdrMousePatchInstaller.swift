import Darwin
import Foundation

/// The impure half of the feature: real file moves against a real herdr
/// binary, tested against a temporary directory tree rather than the real
/// install. Every path is a parameter; nothing here assumes where herdr
/// actually lives.
public enum HerdrMousePatchInstaller {
    public enum InstallError: Error, Equatable {
        case sourceUnreadable
        case backupAlreadyExists
        case destinationNotWritable
        case renameFailed(errno: Int32)
        case verificationFailed
    }

    public enum RevertError: Error, Equatable {
        case backupMissing
        case destinationNotWritable
        case renameFailed(errno: Int32)
        case verificationFailed
    }

    public struct Probe: Equatable, Sendable {
        public let hasVerbs: Bool
        public let hasBackup: Bool
        public let isWritable: Bool
        public let versionSupported: Bool
    }

    public static func backupPath(for binaryPath: String) -> String {
        sibling(of: binaryPath, suffix: ".pre-flock-mouse-backup")
    }

    public static func stagingPath(for binaryPath: String) -> String {
        sibling(of: binaryPath, suffix: ".flock-mouse-staging")
    }

    /// The three filesystem questions decision-making needs, read fresh every
    /// time rather than cached: a herdr upgrade replacing the binary out from
    /// under a stale answer is the ordinary case this exists to notice.
    public static func probe(binaryPath: String, fileManager: FileManager = .default) -> Probe {
        let data = fileManager.contents(atPath: binaryPath) ?? Data()
        return Probe(
            hasVerbs: HerdrMouseVerbs.present(in: data),
            hasBackup: fileManager.fileExists(atPath: backupPath(for: binaryPath)),
            isWritable: fileManager.isWritableFile(atPath: directory(of: binaryPath)),
            versionSupported: HerdrMousePatchVersion.matches(HerdrMousePatchVersion.supported, in: data)
        )
    }

    /// 1. Copy the current binary to a backup beside it -- kept even if a
    ///    later step fails, since nothing has touched the live binary yet.
    /// 2. Copy the artifact to a staging name in the same directory.
    /// 3. Rename staging over the live binary: a `rename(2)` on the same
    ///    volume repoints the directory entry without touching the inode a
    ///    running process already has open, so an in-flight herdr keeps its
    ///    image undisturbed.
    /// 4. Verify the installed file carries the verbs. A failure here rolls
    ///    the rename back from the backup rather than leaving an unverified
    ///    binary in place.
    public static func install(artifactPath: String, binaryPath: String, fileManager: FileManager = .default) throws {
        guard fileManager.isReadableFile(atPath: artifactPath) else { throw InstallError.sourceUnreadable }
        let backup = backupPath(for: binaryPath)
        guard !fileManager.fileExists(atPath: backup) else { throw InstallError.backupAlreadyExists }
        guard fileManager.isWritableFile(atPath: directory(of: binaryPath)) else {
            throw InstallError.destinationNotWritable
        }

        try fileManager.copyItem(atPath: binaryPath, toPath: backup)

        let staging = stagingPath(for: binaryPath)
        if fileManager.fileExists(atPath: staging) {
            try fileManager.removeItem(atPath: staging)
        }
        try fileManager.copyItem(atPath: artifactPath, toPath: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging)

        do {
            try atomicRename(from: staging, to: binaryPath)
        } catch let failure as RenameFailure {
            try? fileManager.removeItem(atPath: staging)
            try? fileManager.removeItem(atPath: backup)
            throw InstallError.renameFailed(errno: failure.errno)
        }

        guard HerdrMouseVerbs.present(in: fileManager.contents(atPath: binaryPath) ?? Data()) else {
            // The backup is still an intact copy (step 1 copied rather than
            // moved it), so renaming it back over the failed install
            // restores exactly what was there before this call.
            try? atomicRename(from: backup, to: binaryPath)
            throw InstallError.verificationFailed
        }
    }

    /// Restores the backup by the same rename install uses, so a running
    /// herdr is undisturbed by revert too. Works with no artifact anywhere on
    /// disk, since it never reads one: revert is only ever a file move.
    public static func revert(binaryPath: String, fileManager: FileManager = .default) throws {
        let backup = backupPath(for: binaryPath)
        guard fileManager.fileExists(atPath: backup) else { throw RevertError.backupMissing }
        guard fileManager.isWritableFile(atPath: directory(of: binaryPath)) else {
            throw RevertError.destinationNotWritable
        }

        do {
            try atomicRename(from: backup, to: binaryPath)
        } catch let failure as RenameFailure {
            throw RevertError.renameFailed(errno: failure.errno)
        }

        guard !HerdrMouseVerbs.present(in: fileManager.contents(atPath: binaryPath) ?? Data()) else {
            throw RevertError.verificationFailed
        }
    }

    private static func sibling(of path: String, suffix: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix).path
    }

    private static func directory(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private struct RenameFailure: Error { let errno: Int32 }

    private static func atomicRename(from: String, to: String) throws {
        guard Darwin.rename(from, to) == 0 else {
            throw RenameFailure(errno: errno)
        }
    }
}
