import XCTest
@testable import FlockCore

final class HerdrStoreBackoffTests: XCTestCase {
    func testBackoffNeverWaitsMoreThanTwoSeconds() {
        XCTAssertEqual(HerdrStore.defaultBackoff(attempt: 1), .milliseconds(500))
        XCTAssertEqual(HerdrStore.defaultBackoff(attempt: 50), .seconds(2))
    }
}
