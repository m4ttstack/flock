import XCTest
@testable import FlockCore

final class ChatAvailabilityTests: XCTestCase {
    func testAnOverrideWinsOverEveryCandidate() {
        XCTAssertEqual(
            ChatAvailability.resolve(environmentOverride: "/opt/chat", candidates: [("/a", 5), ("/b", 9)]),
            "/opt/chat"
        )
    }

    /// Two installs of the same plugin are normal here, and the one built most
    /// recently is the one the user last asked for.
    func testTheNewestCandidateWins() {
        XCTAssertEqual(
            ChatAvailability.resolve(environmentOverride: nil, candidates: [("/a", 5), ("/b", 9), ("/c", 1)]),
            "/b"
        )
    }

    /// Absent is a first-class answer, not an error to report.
    func testNoOverrideAndNoCandidatesIsAbsent() {
        XCTAssertNil(ChatAvailability.resolve(environmentOverride: nil, candidates: []))
    }

    /// An empty override is a variable someone unset badly, not a path.
    func testAnEmptyOverrideIsIgnored() {
        XCTAssertEqual(
            ChatAvailability.resolve(environmentOverride: "", candidates: [("/a", 5)]),
            "/a"
        )
    }
}
