import CryptoKit
import Foundation
import Synchronization

public protocol HerdrDownloadTransport: Sendable {
    /// Downloads `url` to `destination`. Throws on any transport or HTTP failure.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Puts a build in the cache and hands back its path only once its SHA-256
/// matches the expected one: the installer never sees an unverified byte.
public struct HerdrBuildDownloader: Sendable {
    public enum Failure: Error, Equatable { case transport, checksumMismatch }

    private let cacheDirectory: URL
    private let transport: HerdrDownloadTransport

    public init(cacheDirectory: URL, transport: HerdrDownloadTransport) {
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    public func fetch(
        url: URL, sha256: String, fileName: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = cacheDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: cached.path) {
            if (try? Self.sha256(ofFileAt: cached)) == sha256 { return cached.path }
            try fileManager.removeItem(at: cached)
        }
        // A quit mid-download skips the `defer` below and strands a partial of
        // up to the build's full size.
        let partialPrefix = fileName + ".partial-"
        for name in (try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [] where name.hasPrefix(partialPrefix) {
            try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(name))
        }

        let partial = cacheDirectory.appendingPathComponent(fileName + ".partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: partial) }
        do {
            try await transport.download(url, to: partial, progress: progress)
        } catch {
            throw Failure.transport
        }
        guard (try? Self.sha256(ofFileAt: partial)) == sha256 else { throw Failure.checksumMismatch }
        try fileManager.moveItem(at: partial, to: cached)
        // A quarantined helper binary is refused by Gatekeeper when a bridge execs it.
        removexattr(cached.path, "com.apple.quarantine", 0)
        return cached.path
    }

    public static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession reports progress per received chunk, thousands of times for a
/// 20 MB build; each report that passes costs a main-actor hop and a redraw.
public final class HerdrDownloadProgressThrottle: Sendable {
    private let lastReported = Mutex<Double?>(nil)
    private let step: Double

    public init(step: Double = 0.01) {
        self.step = step
    }

    public func shouldReport(_ fraction: Double) -> Bool {
        lastReported.withLock { last in
            if let last, fraction - last < step, !(fraction >= 1 && last < 1) { return false }
            last = fraction
            return true
        }
    }
}
