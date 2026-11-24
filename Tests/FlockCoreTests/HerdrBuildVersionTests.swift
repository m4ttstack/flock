import XCTest

@testable import FlockCore

final class HerdrBuildVersionTests: XCTestCase {
    func testParsesStockAndForkVersionLines() throws {
        let stock = try XCTUnwrap(HerdrBuildVersion.parse(versionOutput: "herdr 0.9.5\n"))
        XCTAssertEqual(stock.base, "0.9.5")
        XCTAssertNil(stock.forkRevision)
        XCTAssertEqual(stock.display, "0.9.5")
        XCTAssertFalse(stock.isMattstackBuild)

        let fork = try XCTUnwrap(HerdrBuildVersion.parse(versionOutput: "herdr 0.9.5-ms.1\n"))
        XCTAssertEqual(fork.base, "0.9.5")
        XCTAssertEqual(fork.forkRevision, 1)
        XCTAssertEqual(fork.display, "0.9.5-ms.1")
        XCTAssertTrue(fork.isMattstackBuild)

        XCTAssertEqual(HerdrBuildVersion.parse(versionOutput: "herdr 0.10.12-ms.14")?.forkRevision, 14)
    }

    func testRejectsAnythingElse() {
        for output in [
            "", "herdr", "0.9.5", "herdr v0.9.5", "herdr 0.9.5-beta", "herdr 0.9.5-ms.", "herdr 0.9.5-ms.0",
            "herdr 0.9.5-ms.x", "herdr 0.9.5-ms.1-ms.2", "herdr 0.9.", "herdr 9", "Herdr 0.9.5", "herdr  0.9.5",
            "herdr 0.9.5 build", "herdr 0.9.5\nherdr 0.9.6",
        ] {
            XCTAssertNil(HerdrBuildVersion.parse(versionOutput: output), output)
        }
    }

    func testInitTakesTheBareVersion() {
        XCTAssertEqual(HerdrBuildVersion("0.9.5-ms.2")?.forkRevision, 2)
        XCTAssertNil(HerdrBuildVersion("herdr 0.9.5"))
    }

    func testOrdering() throws {
        func v(_ s: String) throws -> HerdrBuildVersion { try XCTUnwrap(HerdrBuildVersion(s)) }
        XCTAssertTrue(try v("0.9.5-ms.1").isOlder(than: v("0.9.5-ms.2")))
        XCTAssertTrue(try v("0.9.5-ms.3").isOlder(than: v("0.9.6-ms.1")))
        XCTAssertTrue(try v("0.9.9-ms.4").isOlder(than: v("0.9.10-ms.1")))
        XCTAssertTrue(try v("0.9.5").isOlder(than: v("0.9.5-ms.1")))
        XCTAssertFalse(try v("0.9.5-ms.2").isOlder(than: v("0.9.5-ms.2")))
    }
}
