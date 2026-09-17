import XCTest
@testable import FlockCore

final class FlockCoreTests: XCTestCase {
    func testName() {
        XCTAssertEqual(FlockCore.name, "FlockCore")
    }
}
