import XCTest
@testable import FlockCore

final class WrappingStepTests: XCTestCase {
    func testStepsAndWrapsAtBothEnds() {
        XCTAssertEqual(WrappingStep.neighbor(of: "b", in: ["a", "b", "c"], step: 1), "c")
        XCTAssertEqual(WrappingStep.neighbor(of: "c", in: ["a", "b", "c"], step: 1), "a")
        XCTAssertEqual(WrappingStep.neighbor(of: "a", in: ["a", "b", "c"], step: -1), "c")
    }

    func testNothingToGoTo() {
        XCTAssertNil(WrappingStep.neighbor(of: "a", in: ["a"], step: 1))
        XCTAssertNil(WrappingStep.neighbor(of: "z", in: ["a", "b"], step: 1))
        XCTAssertNil(WrappingStep.neighbor(of: nil as String?, in: ["a", "b"], step: 1))
    }
}
