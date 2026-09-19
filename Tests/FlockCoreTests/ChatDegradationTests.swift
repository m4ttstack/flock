import XCTest
@testable import FlockCore

/// The pure half of the degradation matrix: what "available" means, whether
/// a verb is allowed to run, and what disables Open Viewer alone. The
/// view-level rows (the Retry line, Open viewer's disabled reason on
/// screen) are render tests in Tests/FlockChromeRender, since FlockCore has
/// no views.
final class ChatDegradationTests: XCTestCase {
    // MARK: - herdr-chat binary missing -> absent

    func testMissingTheChatBinaryIsUnavailableEvenWithRTPresent() {
        XCTAssertFalse(ChatDegradation.isAvailable(chatBinaryFound: false, rtBinaryFound: true))
    }

    // MARK: - rt binary missing -> the same absence, not a broken state

    func testMissingRTIsUnavailableEvenWithTheChatBinaryPresent() {
        XCTAssertFalse(ChatDegradation.isAvailable(chatBinaryFound: true, rtBinaryFound: false))
    }

    func testBothPresentIsAvailable() {
        XCTAssertTrue(ChatDegradation.isAvailable(chatBinaryFound: true, rtBinaryFound: true))
    }

    // MARK: - whether a verb runs at all when unavailable

    func testNoVerbRunsWhenUnavailable() {
        XCTAssertFalse(ChatDegradation.shouldRunVerb(isAvailable: false))
    }

    func testAVerbRunsWhenAvailable() {
        XCTAssertTrue(ChatDegradation.shouldRunVerb(isAvailable: true))
    }

    // MARK: - absent and broken can never collapse into each other

    /// Absence is a fact computed before any call ever runs; brokenness is a
    /// thrown failure from a call's own outcome. Proving both from the same
    /// inputs shows they are structurally different, never the same value
    /// read two ways.
    func testAbsentAndBrokenAreNeverTheSameShape() {
        let absent = ChatDegradation.isAvailable(chatBinaryFound: false, rtBinaryFound: true)
        XCTAssertFalse(absent, "a missing binary is silent absence, not a failure")

        let daemonDownJSON = Data(#"{"error":"chat daemon unreachable"}"#.utf8)
        XCTAssertThrowsError(
            try ChatOutcome.decode(ChatStatus.self, stdout: daemonDownJSON, exitCode: 1),
            "chat available but the call itself failing must throw, never read as absence"
        ) { error in
            XCTAssertEqual((error as? ChatFailure)?.message, "chat daemon unreachable")
        }
    }

    // MARK: - deck missing disables Open Viewer alone

    func testDeckMissingNamesItsOwnReason() {
        XCTAssertNotNil(ChatDegradation.viewerDisabledReason(deckBinaryFound: false))
    }

    func testDeckPresentMeansNoReason() {
        XCTAssertNil(ChatDegradation.viewerDisabledReason(deckBinaryFound: true))
    }

    /// Deck never figures into the whole-feature gate: only the plugin
    /// binary and rt do.
    func testDeckAbsenceNeverTouchesTheWholeFeatureGate() {
        XCTAssertTrue(ChatDegradation.isAvailable(chatBinaryFound: true, rtBinaryFound: true))
        XCTAssertNotNil(ChatDegradation.viewerDisabledReason(deckBinaryFound: false))
    }
}
