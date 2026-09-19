import XCTest
@testable import FlockCore

final class ChatBroadcastSummaryTests: XCTestCase {
    func testEveryPaneAcceptedRaisesNoToast() {
        let broadcast = ChatBroadcast(ok: true, results: [
            result("w1:p1", delivered: "accepted"),
            result("w1:p2", delivered: "accepted"),
        ])
        XCTAssertNil(ChatBroadcastSummary.message(for: broadcast))
    }

    /// The rule this whole type exists for: `queued` is rt taking
    /// responsibility for the message, not a failure, so it must read
    /// exactly like `accepted` -- no toast either way.
    func testOneQueuedAndOneAcceptedRaisesNoToast() {
        let broadcast = ChatBroadcast(ok: true, results: [
            result("w1:p1", delivered: "queued"),
            result("w1:p2", delivered: "accepted"),
        ])
        XCTAssertNil(ChatBroadcastSummary.message(for: broadcast))
    }

    func testOneRefusedAmongThreeNamesThatPaneInTheToast() throws {
        let broadcast = ChatBroadcast(ok: true, results: [
            result("w1:p1", delivered: "accepted"),
            result("w1:p2", delivered: "refused"),
            result("w1:p3", delivered: "queued"),
        ])
        let message = try XCTUnwrap(ChatBroadcastSummary.message(for: broadcast))
        XCTAssertTrue(message.contains("w1:p2"), message)
    }

    func testEveryPaneRefusedRaisesAToastSayingSo() throws {
        let broadcast = ChatBroadcast(ok: false, results: [
            result("w1:p1", delivered: "refused"),
            result("w1:p2", delivered: "refused"),
        ])
        let message = try XCTUnwrap(ChatBroadcastSummary.message(for: broadcast))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("refused"), message)
    }
}

private func result(_ paneID: String, delivered: String) -> ChatBroadcastResult {
    let json = #"{"paneId":"\#(paneID)","ok":\#(delivered == "refused" ? "false" : "true"),"delivered":"\#(delivered)","error":null}"#
    return try! JSONDecoder().decode(ChatBroadcastResult.self, from: Data(json.utf8))
}
