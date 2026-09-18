import XCTest
@testable import FlockCore

final class ChatShapesTests: XCTestCase {
    /// The far side prints paneId; Swift spells it paneID. A rename on either
    /// side breaks this silently, so it is asserted rather than assumed.
    func testABuddyReadsThePaneIdItWasPrintedUnder() throws {
        let json = #"""
        {"handle":"kay","paneId":"w1:p1","status":"live","repo":null,"branch":null,"title":null,"unread":2,"mentions":0}
        """#
        let buddy = try JSONDecoder().decode(ChatBuddy.self, from: Data(json.utf8))
        XCTAssertEqual(buddy.paneID, "w1:p1")
        XCTAssertEqual(buddy.unread, 2)
        XCTAssertNil(buddy.repo)
    }

    func testABroadcastResultReadsItsPaneIdAndDeliveredWord() throws {
        let json = #"{"paneId":"w1:p1","ok":true,"delivered":"queued","error":null}"#
        let result = try JSONDecoder().decode(ChatBroadcastResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.paneID, "w1:p1")
        XCTAssertEqual(result.delivered, "queued")
    }
}
