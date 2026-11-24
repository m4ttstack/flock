import CryptoKit
import Darwin
import Foundation

/// The impure half of installing a build: real file moves against a real
/// herdr binary, tested against a temporary directory tree. Every path is a
/// parameter.
public enum HerdrBuildInstaller {
    public enum InstallError: Error, Equatable {
        case sourceUnreadable
        case checksumMismatch
        case destinationNotWritable
        case renameFailed(errno: Int32)
    }

    public struct Probe: Equatable, Sendable {
        public let exists: Bool
        public let isWritable: Bool
        public let version: HerdrBuildVersion?
        public let sha256: String?

        public init(exists: Bool, isWritable: Bool, version: HerdrBuildVersion?, sha256: String?) {
            self.exists = exists
            self.isWritable = isWritable
            self.version = version
            self.sha256 = sha256
        }
    }

    public static func fileName(for version: HerdrBuildVersion, arch: HerdrArch) -> String {
        "herdr-\(version.display)-\(arch.rawValue)"
    }

    /// Read fresh every time: a herdr upgrade replacing the binary under a
    /// stale answer is the ordinary case. `readVersionOutput` returns what
    /// `herdr --version` printed for the binary at a path, nil when it could
    /// not be run, and is never called for a missing binary.
    public static func probe(
        binaryPath: String, fileManager: FileManager = .default, readVersionOutput: (String) -> String?
    ) -> Probe {
        guard let data = fileManager.contents(atPath: binaryPath) else {
            return Probe(exists: false, isWritable: isWritableOrCreatable(directory(of: binaryPath), fileManager), version: nil, sha256: nil)
        }
        return Probe(
            exists: true,
            isWritable: fileManager.isWritableFile(atPath: directory(of: binaryPath)),
            version: readVersionOutput(binaryPath).flatMap { HerdrBuildVersion.parse(versionOutput: $0) },
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    /// 1. Create the parent directory when it is missing.
    /// 2. Copy the artifact to a staging name beside the binary and verify
    ///    its SHA-256 there, so a mismatch never touches the live binary.
    /// 3. Rename staging over the binary: `rename(2)` repoints the directory
    ///    entry without touching the inode a running herdr has open.
    public static func install(
        artifactPath: String, binaryPath: String, sha256: String, fileManager: FileManager = .default
    ) throws {
        guard fileManager.isReadableFile(atPath: artifactPath) else { throw InstallError.sourceUnreadable }
        let directory = directory(of: binaryPath)
        guard isWritableOrCreatable(directory, fileManager) else { throw InstallError.destinationNotWritable }
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw InstallError.destinationNotWritable
        }

        let staging = binaryPath + ".flock-staging"
        if fileManager.fileExists(atPath: staging) { try fileManager.removeItem(atPath: staging) }
        try fileManager.copyItem(atPath: artifactPath, toPath: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging)
        guard (try? HerdrBuildDownloader.sha256(ofFileAt: URL(fileURLWithPath: staging))) == sha256 else {
            try? fileManager.removeItem(atPath: staging)
            throw InstallError.checksumMismatch
        }
        removexattr(staging, "com.apple.quarantine", 0)

        guard Darwin.rename(staging, binaryPath) == 0 else {
            let failure = errno
            try? fileManager.removeItem(atPath: staging)
            throw InstallError.renameFailed(errno: failure)
        }
    }

    private static func directory(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// Whether files can be written in `directory`, or in the nearest
    /// existing ancestor when it does not exist yet.
    private static func isWritableOrCreatable(_ directory: String, _ fileManager: FileManager) -> Bool {
        var url = URL(fileURLWithPath: directory)
        while !fileManager.fileExists(atPath: url.path), url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return fileManager.isWritableFile(atPath: url.path)
    }
}
