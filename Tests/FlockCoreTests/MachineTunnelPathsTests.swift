import XCTest
@testable import FlockCore

final class MachineTunnelPathsTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef"

    func testPathsFitTheSocketLimitAndDifferByApp() {
        let dev = MachineTunnelPaths(uid: 501, bundleTag: "dev", machineID: id)
        let rel = MachineTunnelPaths(uid: 501, bundleTag: "rel", machineID: id)
        XCTAssertEqual(dev.apiSocket, "/tmp/flock-501/dev-0123456789ab/herdr.sock")
        XCTAssertEqual(dev.clientSocket, "/tmp/flock-501/dev-0123456789ab/herdr-client.sock")
        XCTAssertNotEqual(dev.directory, rel.directory)
        XCTAssertLessThanOrEqual(dev.clientSocket.utf8.count, 104)
    }

    func testStaleEntriesAreOnlyThisAppsTunnelDirectories() {
        let entries = ["dev-0123456789ab", "rel-0123456789ab", "dev-", "devx-0123", "dev", "abcd1234-0123", "dev-fedcba987654"]
        XCTAssertEqual(MachineTunnelPaths.staleEntries(entries, bundleTag: "dev"), ["dev-0123456789ab", "dev-fedcba987654"])
        XCTAssertEqual(MachineTunnelPaths.root(uid: 501), "/tmp/flock-501")
        XCTAssertTrue(MachineTunnelPaths(uid: 501, bundleTag: "dev", machineID: id).directory.hasPrefix("/tmp/flock-501/"))
    }

    func testBundleTags() {
        XCTAssertEqual(MachineTunnelPaths.bundleTag(for: "dev.mattstack.Flock"), "rel")
        XCTAssertEqual(MachineTunnelPaths.bundleTag(for: "dev.mattstack.Flock.dev"), "dev")
        let other = MachineTunnelPaths.bundleTag(for: "com.example.Other")
        XCTAssertEqual(other.count, 8)
        XCTAssertTrue(other.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(other, MachineTunnelPaths.bundleTag(for: "com.example.Other"))
    }
}
