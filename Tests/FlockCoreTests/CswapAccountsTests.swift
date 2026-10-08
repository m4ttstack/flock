import XCTest
@testable import FlockCore

final class CswapAccountsTests: XCTestCase {
    private let work = CswapAccount(number: 1, email: "dev@acme.test", organizationName: "Acme", alias: nil)
    private let personal = CswapAccount(
        number: 2, email: "me@example.test", organizationName: "me@example.test's Organization", alias: "home"
    )

    func testParseReadsEachAccountFromListJSON() {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": 2, "accounts": [
          {"number": 1, "email": "dev@acme.test", "organizationName": "Acme", "active": false, "usage": {}},
          {"number": 2, "email": "me@example.test", "organizationName": "me@example.test's Organization",
           "alias": "home", "active": true}
        ]}
        """
        XCTAssertEqual(CswapAccountList.parse(Data(json.utf8)), [work, personal])
    }

    func testParseRejectsANewerSchema() {
        let json = #"{"schemaVersion": 2, "accounts": [{"number": 1, "email": "dev@acme.test"}]}"#
        XCTAssertNil(CswapAccountList.parse(Data(json.utf8)))
    }

    func testParseRejectsOutputThatIsNotJSON() {
        XCTAssertNil(CswapAccountList.parse(Data("Accounts:\n  1: dev@acme.test".utf8)))
    }

    func testLabelPrefersAliasThenOrganizationThenEmail() {
        XCTAssertEqual(personal.label, "home")
        XCTAssertEqual(work.label, "dev@acme.test \u{00B7} Acme")
        let solo = CswapAccount(number: 3, email: "me@example.test", organizationName: "me@example.test's Organization", alias: nil)
        XCTAssertEqual(solo.label, "me@example.test", "a personal org says nothing the email does not")
    }

    func testClaudeWithAKnownAccountRunsThroughCswap() {
        let line = ClaudeAccountLaunch.line(binary: "claude", account: "dev@acme.test", accounts: [work, personal])
        XCTAssertEqual(line, ClaudeLaunchLine(text: "cswap run 'dev@acme.test'", unavailableAccount: nil))
    }

    func testAccountMatchesIgnoringCase() {
        let line = ClaudeAccountLaunch.line(binary: "claude", account: "DEV@acme.test", accounts: [work])
        XCTAssertEqual(line.text, "cswap run 'dev@acme.test'")
    }

    func testClaudeWithNoAccountIsPlainClaude() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "claude", account: nil, accounts: [work]),
            ClaudeLaunchLine(text: "claude", unavailableAccount: nil)
        )
    }

    func testAnotherHarnessIgnoresTheAccount() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "codex", account: "dev@acme.test", accounts: [work]),
            ClaudeLaunchLine(text: "codex", unavailableAccount: nil)
        )
    }

    func testAnAccountCswapNoLongerHasFallsBackToPlainClaude() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "claude", account: "gone@acme.test", accounts: [work]),
            ClaudeLaunchLine(text: "claude", unavailableAccount: "gone@acme.test")
        )
    }

    func testNoCswapFallsBackToPlainClaude() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "claude", account: "dev@acme.test", accounts: nil),
            ClaudeLaunchLine(text: "claude", unavailableAccount: "dev@acme.test")
        )
    }

    func testMenuIsAbsentWithoutCswap() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: "dev@acme.test", accounts: nil), [])
    }

    func testMenuOffersCurrentLoginThenEachAccountWithTheSavedOneChecked() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: "dev@acme.test", accounts: [work, personal]), [
            .init(label: "Current Login", account: nil, isChecked: false),
            .init(label: "dev@acme.test \u{00B7} Acme", account: "dev@acme.test", isChecked: true),
            .init(label: "home", account: "me@example.test", isChecked: false),
        ])
    }

    func testMenuChecksCurrentLoginWhenNothingIsSaved() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: nil, accounts: [work]).first?.isChecked, true)
    }

    func testMenuKeepsASavedAccountCswapNoLongerHas() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: "gone@acme.test", accounts: [work]).last,
                       .init(label: "gone@acme.test (not in cswap)", account: "gone@acme.test", isChecked: true))
    }
}
