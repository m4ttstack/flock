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

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// An older herdr-chat prints no `name` key at all. That must decode, and
    /// the handle (a legacy identity's own name) is what gets drawn.
    func testABuddyWithNoNameKeyDrawsItsHandle() throws {
        let buddy = try decode(
            ChatBuddy.self,
            #"{"handle":"kay","paneId":"w1:p1","status":"idle","repo":null,"branch":null,"title":null,"unread":0,"mentions":0}"#
        )
        XCTAssertNil(buddy.name)
        XCTAssertEqual(buddy.displayName, "kay")
    }

    func testABuddyWithANameDrawsTheNameAndKeepsTheIdAsItsHandle() throws {
        let buddy = try decode(
            ChatBuddy.self,
            #"{"handle":"kay.k3f9","name":"kay","paneId":"w1:p1","status":"idle","repo":null,"branch":null,"title":null,"unread":0,"mentions":0}"#
        )
        XCTAssertEqual(buddy.handle, "kay.k3f9")
        XCTAssertEqual(buddy.name, "kay")
        XCTAssertEqual(buddy.displayName, "kay")
    }

    func testAStatusDecodesItsNameAbsentNullOrPresent() throws {
        let absent = try decode(ChatStatus.self, #"{"handle":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[]}"#)
        XCTAssertNil(absent.name)
        XCTAssertEqual(absent.displayName, "kay")

        let explicitNull = try decode(
            ChatStatus.self, #"{"handle":"kay","name":null,"state":"live","pane":"w1:p1","signedIn":true,"rooms":[]}"#
        )
        XCTAssertNil(explicitNull.name)
        XCTAssertEqual(explicitNull.displayName, "kay")

        let present = try decode(
            ChatStatus.self, #"{"handle":"kay.k3f9","name":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[]}"#
        )
        XCTAssertEqual(present.handle, "kay.k3f9")
        XCTAssertEqual(present.displayName, "kay")
    }

    func testASignedOutStatusHasNoDisplayName() throws {
        let status = try decode(
            ChatStatus.self, #"{"handle":null,"name":null,"state":"not signed in","pane":null,"signedIn":false,"rooms":[]}"#
        )
        XCTAssertNil(status.displayName)
    }

    func testAJumpDecodesItsNameAbsentOrPresent() throws {
        let absent = try decode(ChatJump.self, #"{"paneId":"w1:p3","workspace":"acme","handle":"kay"}"#)
        XCTAssertNil(absent.name)
        XCTAssertEqual(absent.handle, "kay")

        let present = try decode(ChatJump.self, #"{"paneId":"w1:p3","workspace":"acme","handle":"kay.k3f9","name":"kay"}"#)
        XCTAssertEqual(present.handle, "kay.k3f9")
        XCTAssertEqual(present.name, "kay")
    }

    /// The one `@` rule: identity text never carries one, whichever field it
    /// came from, and an empty name is no name.
    func testDisplayTextDropsALeadingAtSignAndIgnoresAnEmptyName() {
        XCTAssertEqual(ChatDisplayName.text(name: nil, handle: "@kay"), "kay")
        XCTAssertEqual(ChatDisplayName.text(name: "@kay", handle: "kay.k3f9"), "kay")
        XCTAssertEqual(ChatDisplayName.text(name: "", handle: "kay"), "kay")
        XCTAssertEqual(ChatDisplayName.text(name: "remy-2", handle: "remy.k3f9"), "remy-2")
    }

    /// herdr-chat labels a DM room by its participants; an older herdr-chat
    /// sends no label, and the raw room is drawn.
    func testAPeekRoomDecodesItsLabelAbsentOrPresent() throws {
        let absent = try decode(ChatPeekRoom.self, #"{"room":"rt","unread":0,"mentions":0}"#)
        XCTAssertNil(absent.label)
        let present = try decode(ChatPeekRoom.self, #"{"room":"dm-3f9a","label":"kai ↔ remy","unread":2,"mentions":0}"#)
        XCTAssertEqual(present.room, "dm-3f9a")
        XCTAssertEqual(present.label, "kai ↔ remy")
    }

    func testTargetsDecodeTheirLabelsAbsentOrPresent() throws {
        let absent = try decode(ChatTargets.self, #"""
        {"rooms":["#rt"],"people":["@kay"]}
        """#)
        XCTAssertNil(absent.labels)
        let present = try decode(
            ChatTargets.self, #"""
            {"rooms":["#rt","#dm-3f9a"],"people":["@kay"],"labels":{"#rt":"#rt","#dm-3f9a":"kai ↔ remy","@kay":"@kay"}}
            """#
        )
        XCTAssertEqual(present.rooms, ["#rt", "#dm-3f9a"])
        XCTAssertEqual(present.labels?["#dm-3f9a"], "kai ↔ remy")
    }
}
