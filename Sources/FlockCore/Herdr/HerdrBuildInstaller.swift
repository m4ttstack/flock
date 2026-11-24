import CryptoKit
import Darwin
import Foundation

public enum HerdrBuildInstaller {
    public enum InstallError: Error, Equatable {
        case sourceUnreadable
        case checksumMismatch
        case destinationNotWritable
        case renameFailed(errno: Int32)
        case stagingFailed
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

    /// `readVersionOutput` is never called for a binary that cannot be read.
    /// A herdr that exists but is unreadable still `exists`, so it is never
    /// treated as missing.
    public static func probe(
        binaryPath: String, fileManager: FileManager = .default, readVersionOutput: (String) -> String?
    ) -> Probe {
        guard fileManager.fileExists(atPath: binaryPath) else {
            return Probe(exists: false, isWritable: isWritableOrCreatable(directory(of: binaryPath), fileManager), version: nil, sha256: nil)
        }
        let data = fileManager.contents(atPath: binaryPath)
        return Probe(
            exists: true,
            isWritable: fileManager.isWritableFile(atPath: directory(of: binaryPath)),
            version: data == nil ? nil : readVersionOutput(binaryPath).flatMap { HerdrBuildVersion.parse(versionOutput: $0) },
            sha256: data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        )
    }

    /// Verified on a staging file beside the binary, so a mismatch never
    /// touches the live one. The final `rename(2)` repoints the directory
    /// entry without touching the inode a running herdr has open.
    public static func install(
        artifactPath: String, binaryPath: String, sha256: String, fileManager: FileManager = .default,
        removeQuarantine: (String) -> Int32 = removeQuarantine(at:)
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
        do {
            if fileManager.fileExists(atPath: staging) { try fileManager.removeItem(atPath: staging) }
            try fileManager.copyItem(atPath: artifactPath, toPath: staging)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging)
        } catch {
            try? fileManager.removeItem(atPath: staging)
            throw InstallError.stagingFailed
        }
        guard (try? HerdrBuildDownloader.sha256(ofFileAt: URL(fileURLWithPath: staging))) == sha256 else {
            try? fileManager.removeItem(atPath: staging)
            throw InstallError.checksumMismatch
        }
        // A quarantined binary is refused by Gatekeeper when it is executed.
        let quarantine = removeQuarantine(staging)
        guard quarantine == 0 || quarantine == ENOATTR else {
            try? fileManager.removeItem(atPath: staging)
            throw InstallError.stagingFailed
        }

        guard Darwin.rename(staging, binaryPath) == 0 else {
            let failure = errno
            try? fileManager.removeItem(atPath: staging)
            throw InstallError.renameFailed(errno: failure)
        }
    }

    /// 0 once the attribute is gone, otherwise the `errno` that kept it.
    public static func removeQuarantine(at path: String) -> Int32 {
        removexattr(path, "com.apple.quarantine", 0) == 0 ? 0 : errno
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
