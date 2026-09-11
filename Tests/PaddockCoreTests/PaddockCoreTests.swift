import XCTest
@testable import PaddockCore

final class PaddockCoreTests: XCTestCase {
    func testName() {
        XCTAssertEqual(PaddockCore.name, "PaddockCore")
    }
}
