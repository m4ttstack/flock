import XCTest
@testable import FlockCore

final class ChatOutcomeTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testASuccessfulRunDecodesItsShape() throws {
        let json = ##"{"handle":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":["#rt"]}"##
        let status = try ChatOutcome.decode(ChatStatus.self, stdout: data(json), exitCode: 0)
        XCTAssertEqual(status.handle, "kay")
        XCTAssertTrue(status.signedIn)
        XCTAssertEqual(status.rooms, ["#rt"])
    }

    /// The far side prints its failure on stdout, not stderr, and exits
    /// non-zero. Reading stderr for it would find nothing.
    func testAFailureIsReadFromStdoutAndCarriesItsMessage() {
        let json = #"{"error":"pane is required"}"#
        XCTAssertThrowsError(try ChatOutcome.decode(ChatStatus.self, stdout: data(json), exitCode: 1)) {
            XCTAssertEqual(($0 as? ChatFailure)?.message, "pane is required")
        }
    }

    /// A non-zero exit with unreadable output is still a failure, and the user
    /// gets something to act on rather than a decode error about JSON.
    func testANonZeroExitWithNoEnvelopeStillFails() {
        XCTAssertThrowsError(try ChatOutcome.decode(ChatStatus.self, stdout: data("boom"), exitCode: 2)) {
            XCTAssertFalse(($0 as? ChatFailure)?.message.isEmpty ?? true)
        }
    }

    /// Absent is null, never a missing key, so an optional stays optional and
    /// a signed-out pane decodes rather than throwing.
    func testNullsDecodeAsAbsentRatherThanFailing() throws {
        let json = #"{"handle":null,"state":"not signed in","pane":null,"signedIn":false,"rooms":[]}"#
        let status = try ChatOutcome.decode(ChatStatus.self, stdout: data(json), exitCode: 0)
        XCTAssertNil(status.handle)
        XCTAssertNil(status.pane)
        XCTAssertFalse(status.signedIn)
    }

    /// Every pane refusing exits 0 with ok:false and a result per pane, which
    /// is a decodable answer rather than an error. Treating the exit code as
    /// the whole story would lose the per-pane detail.
    func testABroadcastWhereEveryPaneRefusedDecodesRatherThanThrowing() throws {
        let json = """
        {"ok":false,"results":[{"paneId":"w1:p1","ok":false,"delivered":"refused","error":"not signed in"}]}
        """
        let out = try ChatOutcome.decode(ChatBroadcast.self, stdout: data(json), exitCode: 0)
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.results.first?.error, "not signed in")
    }
}
