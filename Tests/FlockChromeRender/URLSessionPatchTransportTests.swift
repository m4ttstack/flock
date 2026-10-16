import FlockCore
import XCTest

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class URLSessionPatchTransportTests: XCTestCase {
    private func transport() -> URLSessionPatchTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionPatchTransport(session: URLSession(configuration: config))
    }

    private var destination: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flock-transport-\(UUID().uuidString)")
    }

    func testA200WritesTheBody() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data("bytes".utf8)
        let out = destination
        defer { try? FileManager.default.removeItem(at: out) }
        try await transport().download(URL(string: "https://example.invalid/p")!, to: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out), Data("bytes".utf8))
    }

    func testANon200Throws() async {
        StubProtocol.status = 404
        StubProtocol.body = Data("<html>".utf8)
        let out = destination
        do {
            try await transport().download(URL(string: "https://example.invalid/p")!, to: out, progress: { _ in })
            XCTFail("a 404 must not count as a download")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
