import CryptoKit
import FlockCore
import XCTest

private final class StubTransport: HerdrPatchTransport, @unchecked Sendable {
    var body: Data?
    var error: Error?
    private(set) var calls = 0

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1
        if let error { throw error }
        progress(1)
        try body!.write(to: destination)
    }
}

final class HerdrMousePatchDownloaderTests: XCTestCase {
    private var cache: URL!
    private let good = Data("herdr 0.9.5 terminal.mouse_capture".utf8)

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("flock-patch-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cache)
    }

    private func entry(for data: Data) -> HerdrMousePatchEntry {
        HerdrMousePatchEntry(version: "0.9.5", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testAMatchingDownloadLandsInTheCacheAndIsReturned() async throws {
        let transport = StubTransport()
        transport.body = good
        let path = try await HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport)
            .fetch(entry(for: good), progress: { _ in })
        XCTAssertEqual(path, cache.appendingPathComponent("herdr-mouse-patch-0.9.5-arm64").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), good)
    }

    func testAVerifiedCachedFileIsReusedWithoutDownloading() async throws {
        let transport = StubTransport()
        transport.body = good
        let downloader = HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport)
        _ = try await downloader.fetch(entry(for: good), progress: { _ in })
        _ = try await downloader.fetch(entry(for: good), progress: { _ in })
        XCTAssertEqual(transport.calls, 1)
    }

    func testACachedFileCorruptedOnDiskIsDownloadedAgain() async throws {
        let transport = StubTransport()
        transport.body = good
        let downloader = HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport)
        let path = try await downloader.fetch(entry(for: good), progress: { _ in })
        try Data("corrupted".utf8).write(to: URL(fileURLWithPath: path))
        let again = try await downloader.fetch(entry(for: good), progress: { _ in })
        XCTAssertEqual(transport.calls, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: again)), good)
    }

    func testATruncatedDownloadFailsAndLeavesNothingBehind() async throws {
        let transport = StubTransport()
        transport.body = good.prefix(10)
        await assertFails(.checksumMismatch, HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport), entry(for: good))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testAnErrorPageInPlaceOfTheBinaryFailsTheChecksum() async throws {
        let transport = StubTransport()
        transport.body = Data("<html>Not Found</html>".utf8)
        await assertFails(.checksumMismatch, HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport), entry(for: good))
    }

    func testATransportErrorReportsTransport() async throws {
        let transport = StubTransport()
        transport.error = URLError(.notConnectedToInternet)
        await assertFails(.transport, HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport), entry(for: good))
    }

    private func assertFails(
        _ expected: HerdrMousePatchDownloader.Failure, _ downloader: HerdrMousePatchDownloader, _ entry: HerdrMousePatchEntry,
        line: UInt = #line
    ) async {
        do {
            _ = try await downloader.fetch(entry, progress: { _ in })
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? HerdrMousePatchDownloader.Failure, expected, line: line)
        }
    }
}
