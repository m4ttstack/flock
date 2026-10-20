import FlockCore
import Foundation
import XCTest

final class ChatAutoSignInTests: XCTestCase {
    private func isOn(_ json: String, exitCode: Int32 = 0) -> Bool {
        ChatAutoSignIn.isOn(stdout: Data(json.utf8), exitCode: exitCode)
    }

    func testOnlyADecodedTrueIsOn() {
        XCTAssertTrue(isOn(#"{"ok":true,"key":"chat.autoSignIn","value":true,"provenance":[],"migrated":true}"#))
        XCTAssertFalse(isOn(#"{"ok":true,"key":"chat.autoSignIn","value":false}"#))
        XCTAssertFalse(isOn(#"{"ok":true,"key":"chat.autoSignIn"}"#))
    }

    func testAFailedReadIsOff() {
        XCTAssertFalse(isOn(#"{"ok":true,"value":true}"#, exitCode: 2))
        XCTAssertFalse(isOn("chat.autoSignIn is not a setting rt knows"))
        XCTAssertFalse(isOn(""))
    }

    func testTheSettingIsReadForTheAgentsFolder() {
        XCTAssertEqual(
            ChatAutoSignIn.settingArguments(folder: "/src/acme"),
            ["settings", "get", "chat.autoSignIn", "--repo", "/src/acme", "--json"]
        )
    }

    func testOnlyAClaudeAgentAppearingIsFollowed() {
        XCTAssertTrue(ChatAutoSignIn.shouldFollow(previousAgent: nil, agent: "claude"))
        XCTAssertFalse(ChatAutoSignIn.shouldFollow(previousAgent: nil, agent: "codex"))
        XCTAssertFalse(ChatAutoSignIn.shouldFollow(previousAgent: nil, agent: nil))
        XCTAssertFalse(ChatAutoSignIn.shouldFollow(previousAgent: "claude", agent: "claude"))
        XCTAssertFalse(ChatAutoSignIn.shouldFollow(previousAgent: "claude", agent: nil))
    }
}
