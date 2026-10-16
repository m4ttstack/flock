import CryptoKit
import Foundation
import Synchronization

public protocol HerdrPatchTransport: Sendable {
    /// Downloads `url` to `destination`. Throws on any transport or HTTP failure.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Puts a catalogue patch in the cache and hands back its path only once its
/// SHA-256 matches the catalogue: the installer never sees an unverified byte.
public struct HerdrMousePatchDownloader: Sendable {
    public enum Failure: Error, Equatable { case transport, checksumMismatch }

    private let cacheDirectory: URL
    private let transport: HerdrPatchTransport

    public init(cacheDirectory: URL, transport: HerdrPatchTransport) {
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    public func fetch(_ entry: HerdrMousePatchEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = cacheDirectory.appendingPathComponent(entry.fileName)
        if fileManager.fileExists(atPath: cached.path) {
            if (try? Self.sha256(ofFileAt: cached)) == entry.sha256 { return cached.path }
            try fileManager.removeItem(at: cached)
        }
        // A quit mid-download skips the `defer` below and strands a partial of
        // up to the patch's full size.
        let partialPrefix = entry.fileName + ".partial-"
        for name in (try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [] where name.hasPrefix(partialPrefix) {
            try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(name))
        }

        let partial = cacheDirectory.appendingPathComponent(entry.fileName + ".partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: partial) }
        do {
            try await transport.download(entry.url, to: partial, progress: progress)
        } catch {
            throw Failure.transport
        }
        guard (try? Self.sha256(ofFileAt: partial)) == entry.sha256 else { throw Failure.checksumMismatch }
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
/// 20 MB patch; each report that passes costs a main-actor hop and a redraw.
public final class HerdrPatchProgressThrottle: Sendable {
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
