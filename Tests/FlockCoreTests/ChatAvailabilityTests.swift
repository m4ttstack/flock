import XCTest
@testable import FlockCore

final class ChatAvailabilityTests: XCTestCase {
    private let runnable: Set<String> = ["/override", "/dev", "/bundled"]

    func testTheFirstRunnableCandidateWins() {
        XCTAssertEqual(
            ChatAvailability.resolve(["/override", "/dev", "/bundled"], isRunnable: runnable.contains),
            "/override"
        )
        XCTAssertEqual(
            ChatAvailability.resolve([nil, "/dev", "/bundled"], isRunnable: runnable.contains),
            "/dev"
        )
    }

    /// A typo'd override or an unbuilt dev checkout must fall through to a
    /// real binary rather than report chat present at a dead path.
    func testAnUnrunnableCandidateFallsThrough() {
        XCTAssertEqual(
            ChatAvailability.resolve(["/missing", "/also-missing", "/bundled"], isRunnable: runnable.contains),
            "/bundled"
        )
    }

    /// An empty string is a variable someone unset badly, not a path.
    func testAnEmptyCandidateIsSkippedWithoutAsking() {
        XCTAssertEqual(
            ChatAvailability.resolve(["", "/bundled"], isRunnable: { !$0.isEmpty }),
            "/bundled"
        )
    }

    /// Absent is a first-class answer, not an error to report.
    func testNothingRunnableIsAbsent() {
        XCTAssertNil(ChatAvailability.resolve([nil, "/missing"], isRunnable: runnable.contains))
        XCTAssertNil(ChatAvailability.resolve([], isRunnable: runnable.contains))
    }
}
