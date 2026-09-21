import XCTest
@testable import FlockCore

/// rustc packs adjacent string literals with no separating byte, so a plain
/// substring search for "0.9.1" also matches inside "0.9.12" or "1.0.9.1".
/// These fixtures pin the boundary check that keeps a longer version number
/// from reading as a match.
final class HerdrMousePatchVersionTests: XCTestCase {
    func testMatchesWhenTheVersionStandsAlone() {
        let data = Data("...herdr 0.9.1 build...".utf8)

        XCTAssertTrue(HerdrMousePatchVersion.matches("0.9.1", in: data))
    }

    func testDoesNotMatchALongerVersionThatStartsWithTheSameDigits() {
        let data = Data("parking_lot_core-0.9.12".utf8)

        XCTAssertFalse(HerdrMousePatchVersion.matches("0.9.1", in: data))
    }

    func testDoesNotMatchWhenPrecededByMoreVersionDigits() {
        let data = Data("v1.0.9.1".utf8)

        XCTAssertFalse(HerdrMousePatchVersion.matches("0.9.1", in: data))
    }

    func testMatchesAtTheStartOfTheBuffer() {
        let data = Data("0.9.1".utf8)

        XCTAssertTrue(HerdrMousePatchVersion.matches("0.9.1", in: data))
    }

    func testMatchesAtTheEndOfTheBuffer() {
        let data = Data("CARGO_PKG_VERSION=0.9.1".utf8)

        XCTAssertTrue(HerdrMousePatchVersion.matches("0.9.1", in: data))
    }

    func testDoesNotMatchADifferentVersionEntirely() {
        let data = Data("herdr 0.10.0".utf8)

        XCTAssertFalse(HerdrMousePatchVersion.matches("0.9.1", in: data))
    }

    func testEmptyDataDoesNotMatch() {
        XCTAssertFalse(HerdrMousePatchVersion.matches("0.9.1", in: Data()))
    }
}
