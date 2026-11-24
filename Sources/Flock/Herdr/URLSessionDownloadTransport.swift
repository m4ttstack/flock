import FlockCore
import Foundation

struct URLSessionDownloadTransport: HerdrDownloadTransport {
    struct HTTPStatus: Error { let code: Int }

    var session: URLSession = .shared

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = ProgressDelegate(progress: progress)
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPStatus(code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

extension HerdrBuildDownloader {
    static var standard: HerdrBuildDownloader {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "flock")
            .appendingPathComponent("herdr-builds")
        return HerdrBuildDownloader(cacheDirectory: directory, transport: URLSessionDownloadTransport())
    }
}
