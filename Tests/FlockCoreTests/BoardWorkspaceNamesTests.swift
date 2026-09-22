import XCTest
@testable import FlockCore

final class BoardWorkspaceNamesTests: XCTestCase {
    private func names(_ stdout: String, exitCode: Int32 = 0) -> BoardWorkspaceNames? {
        BoardWorkspaceNames.fromSettingsGet(stdout: Data(stdout.utf8), exitCode: exitCode)
    }

    func testEveryRoleSetIsReadAsIs() {
        let answer = names(
            #"{"ok":true,"key":"board.workspaces","value":{"reviews":"🛹 Reviews","responds":"🛹 Responses","doctors":"🛹 Doctors"},"provenance":[{"scope":"user"}],"migrated":true}"#
        )
        XCTAssertEqual(answer, BoardWorkspaceNames(reviews: "🛹 Reviews", responds: "🛹 Responses", doctors: "🛹 Doctors"))
    }

    func testARoleLeftOutFallsBackToBoardsOwnDefault() {
        let answer = names(#"{"ok":true,"key":"board.workspaces","value":{"responds":"triage"}}"#)
        XCTAssertEqual(answer, BoardWorkspaceNames(reviews: "reviews", responds: "triage", doctors: "doctors"))
    }

    /// rt drops an undefined value from its JSON, so an unset setting comes
    /// back with no `value` key at all. Board then runs on its defaults.
    func testAnUnsetSettingIsEveryDefault() {
        XCTAssertEqual(names(#"{"ok":true,"key":"board.workspaces","provenance":[],"migrated":true}"#), .defaults)
        XCTAssertEqual(names(#"{"ok":true,"key":"board.workspaces","value":null}"#), .defaults)
    }

    func testAFieldThatIsNotANonEmptyStringFallsBack() {
        let answer = names(#"{"ok":true,"value":{"reviews":7,"responds":"","doctors":null}}"#)
        XCTAssertEqual(answer, .defaults)
    }

    func testTheDefaultsAreBoards() {
        XCTAssertEqual(BoardWorkspaceNames.defaults.reviews, "reviews")
        XCTAssertEqual(BoardWorkspaceNames.defaults.responds, "responses")
        XCTAssertEqual(BoardWorkspaceNames.defaults.doctors, "doctors")
    }

    // MARK: - No Board config

    func testANonZeroExitIsNoConfig() {
        XCTAssertNil(names(#"{"ok":true,"value":{"reviews":"r"}}"#, exitCode: 1))
    }

    func testOkFalseIsNoConfig() {
        XCTAssertNil(names(#"{"ok":false,"error":"unknown key board.workspaces"}"#))
    }

    func testOutputThatIsNotTheEnvelopeIsNoConfig() {
        XCTAssertNil(names(""))
        XCTAssertNil(names("rt: command not found"))
        XCTAssertNil(names(#"["reviews"]"#))
        XCTAssertNil(names(#"{"key":"board.workspaces","value":{}}"#), "no ok at all")
        XCTAssertNil(names(#"{"ok":true,"value":"reviews"}"#), "a value that is not an object")
    }

    // MARK: - Membership

    func testLabelsAreInRoleOrderWithASharedNameListedOnce() {
        XCTAssertEqual(BoardWorkspaceNames.defaults.labels, ["reviews", "responses", "doctors"])
        XCTAssertEqual(BoardWorkspaceNames(reviews: "board", responds: "board", doctors: "doctors").labels, ["board", "doctors"])
    }

    func testMembershipIsAnExactLabelMatch() {
        let board = BoardWorkspaceNames(reviews: "🛹 Reviews", responds: "🛹 Responses", doctors: "🛹 Doctors")
        XCTAssertTrue(board.contains(label: "🛹 Doctors"))
        XCTAssertFalse(board.contains(label: "🛹 doctors"))
        XCTAssertFalse(board.contains(label: "🛹 Doctors "))
        XCTAssertFalse(board.contains(label: "Doctors"))
    }
}
