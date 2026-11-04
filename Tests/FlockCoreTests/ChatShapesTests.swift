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

    /// A buddy signed in outside herdr prints `"paneId": null`. Overview and
    /// Arrange read every handle from one peek, so that row alone must not
    /// fail the rest of the list.
    func testAPeekDropsABuddyWithNoPaneAndKeepsTheRest() throws {
        let json = #"""
        {"buddies":[
          {"handle":"kay","paneId":"w1:p1","status":"live","repo":null,"branch":null,"title":null,"unread":0,"mentions":0},
          {"handle":"lou","paneId":null,"status":"live","repo":null,"branch":null,"title":null,"unread":0,"mentions":0}
        ],"rooms":[]}
        """#
        let peek = try JSONDecoder().decode(ChatPeek.self, from: Data(json.utf8))
        XCTAssertEqual(peek.buddies.map(\.handle), ["kay"])
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

    func testAStatusDecodesSlackChat() throws {
        let status = try decode(
            ChatStatus.self,
            #"{"handle":"kay","name":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[],"slackChat":{"name":"alex","openedAt":1700}}"#
        )
        XCTAssertEqual(status.slack, .open(name: "alex"))
    }

    func testSlackChatPrefersItsDisplayName() throws {
        let status = try decode(
            ChatStatus.self,
            #"{"handle":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[],"slackChat":{"name":"alex-slack","displayName":"Alex Example","openedAt":1700}}"#
        )
        XCTAssertEqual(status.slack, .open(name: "Alex Example"))
    }

    func testSlackChatFallsBackToItsNameForAnEmptyDisplayName() throws {
        let status = try decode(
            ChatStatus.self,
            #"{"handle":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[],"slackChat":{"name":"alex-slack","displayName":"","openedAt":1700}}"#
        )
        XCTAssertEqual(status.slack, .open(name: "alex-slack"))
    }

    func testPeopleDecodeWithAndWithoutATitle() throws {
        let reply = try decode(
            ChatSlackPeople.self,
            #"{"ok":true,"people":[{"name":"Alex Example","person":"U0TEST","title":"Support lead"},{"name":"Sam Sample","person":"U0OTHER"}]}"#
        )
        XCTAssertEqual(reply.people, [
            ChatSlackPerson(name: "Alex Example", person: "U0TEST", title: "Support lead"),
            ChatSlackPerson(name: "Sam Sample", person: "U0OTHER", title: nil)
        ])
    }

    /// Slack not connected answers with no list, which the form reads as free text.
    func testAnUnavailableAnswerHasNoPeople() throws {
        let reply = try decode(ChatSlackPeople.self, #"{"ok":false,"reason":"unavailable","error":"no token"}"#)
        XCTAssertNil(reply.people)
    }

    /// Bytes captured from a herdr-chat built with Slack support, so a wire
    /// change fails here rather than in a pane.
    func testHerdrChatsOwnOutputDecodes() throws {
        let status = try decode(
            ChatStatus.self,
            ##"{"handle":"kay.k3f9","name":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":["#rt"],"slackChat":{"name":"alex-slack","displayName":"Alex Example","openedAt":1700}}"##
        )
        XCTAssertEqual(status.slack, .open(name: "Alex Example"))
        XCTAssertEqual(status.rooms, ["#rt"])

        let people = try decode(
            ChatSlackPeople.self,
            #"{"ok":true,"people":[{"name":"Alex Example","person":"U0TEST","title":"Support lead"},{"name":"Sam Other","person":"U0SAM"}]}"#
        )
        XCTAssertEqual(people.people?.map(\.person), ["U0TEST", "U0SAM"])
        XCTAssertNil(people.people?.last?.title)

        let closed = try decode(ChatSlackClosed.self, #"{"ok":true,"conversationId":4,"closed":false}"#)
        XCTAssertFalse(closed.closed)
    }

    /// This one reply exits 0, so `ok` and the missing list are what say so.
    func testAnRtWithNoPeopleVerbReadsAsUnavailable() throws {
        let reply = try ChatOutcome.decode(
            ChatSlackPeople.self,
            stdout: Data(#"{"ok":false,"reason":"unavailable","error":"rt chat has no verb called slack-people"}"#.utf8),
            exitCode: 0
        )
        XCTAssertNil(reply.people)
    }

    func testANullSlackChatMeansSupportedWithNoChatOpen() throws {
        let status = try decode(
            ChatStatus.self, #"{"handle":"kay","name":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[],"slackChat":null}"#
        )
        XCTAssertEqual(status.slack, .noChat)
    }

    /// An older herdr-chat prints no key at all, and that must not read as
    /// null: null offers On, and On would type a command nothing handles.
    func testAnAbsentSlackChatMeansUnsupported() throws {
        let status = try decode(ChatStatus.self, #"{"handle":"kay","state":"live","pane":"w1:p1","signedIn":true,"rooms":[]}"#)
        XCTAssertEqual(status.slack, .unsupported)
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
        XCTAssertEqual(ChatDisplayName.text(name: "@", handle: "kay.k3f9"), "kay.k3f9")
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
