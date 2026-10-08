import XCTest
@testable import FlockCore

final class CswapAccountsTests: XCTestCase {
    private let work = CswapAccount(
        number: 1, email: "dev@acme.test", organizationName: "Acme", organizationUuid: "org-acme", alias: nil
    )
    private let personal = CswapAccount(
        number: 2, email: "me@example.test", organizationName: "me@example.test's Organization",
        organizationUuid: "org-me", alias: "home"
    )
    /// The same email under a second organization, which cswap allows.
    private let workElsewhere = CswapAccount(
        number: 3, email: "dev@acme.test", organizationName: "Beta", organizationUuid: "org-beta", alias: nil
    )

    func testParseReadsEachAccountFromListJSON() {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": 2, "accounts": [
          {"number": 1, "email": "dev@acme.test", "organizationName": "Acme", "organizationUuid": "org-acme",
           "active": false, "usage": {}},
          {"number": 2, "email": "me@example.test", "organizationName": "me@example.test's Organization",
           "organizationUuid": "org-me", "alias": "home", "active": true}
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
        let solo = CswapAccount(
            number: 3, email: "me@example.test", organizationName: "me@example.test's Organization",
            organizationUuid: "org-me", alias: nil
        )
        XCTAssertEqual(solo.label, "me@example.test", "a personal org says nothing the email does not")
    }

    /// By number, read at launch: an email cswap holds under two
    /// organizations is ambiguous to `cswap run`.
    func testClaudeWithAKnownAccountRunsItsNumberThroughCswap() {
        let line = ClaudeAccountLaunch.line(binary: "claude", account: work.ref, accounts: [work, personal])
        XCTAssertEqual(line, ClaudeLaunchLine(text: "cswap run 1", fallback: nil))
    }

    func testTheOrganizationPicksBetweenAccountsSharingAnEmail() {
        let line = ClaudeAccountLaunch.line(binary: "claude", account: workElsewhere.ref, accounts: [work, workElsewhere])
        XCTAssertEqual(line.text, "cswap run 3")
    }

    func testAnAccountWithoutAnOrganizationMatchesByEmailIgnoringCase() {
        let ref = ClaudeAccountRef(email: "DEV@acme.test", organizationUuid: nil)
        XCTAssertEqual(ClaudeAccountLaunch.line(binary: "claude", account: ref, accounts: [work]).text, "cswap run 1")
    }

    func testClaudeWithNoAccountIsPlainClaude() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "claude", account: nil, accounts: [work]),
            ClaudeLaunchLine(text: "claude", fallback: nil)
        )
    }

    func testAnotherHarnessIgnoresTheAccount() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "codex", account: work.ref, accounts: [work]),
            ClaudeLaunchLine(text: "codex", fallback: nil)
        )
    }

    func testAnAccountCswapNoLongerHasFallsBackToPlainClaude() {
        let gone = ClaudeAccountRef(email: "gone@acme.test", organizationUuid: "org-acme")
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "claude", account: gone, accounts: [work]),
            ClaudeLaunchLine(text: "claude", fallback: .notInCswap("gone@acme.test"))
        )
    }

    func testCswapThatCannotBeReadFallsBackToPlainClaude() {
        XCTAssertEqual(
            ClaudeAccountLaunch.line(binary: "claude", account: work.ref, accounts: nil),
            ClaudeLaunchLine(text: "claude", fallback: .cswapUnreadable("dev@acme.test"))
        )
    }

    func testTheNoticeSaysWhyTheAccountWasNotUsed() {
        XCTAssertEqual(
            ClaudeAccountLaunch.notice(pinName: "acme", fallback: .notInCswap("dev@acme.test")),
            "\"acme\"'s account dev@acme.test isn't in cswap; Claude launched on the current login."
        )
        XCTAssertEqual(
            ClaudeAccountLaunch.notice(pinName: "acme", fallback: .cswapUnreadable("dev@acme.test")),
            "cswap couldn't be read, so \"acme\"'s account dev@acme.test wasn't used; Claude launched on the current login."
        )
    }

    func testMenuIsAbsentWithoutCswap() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: work.ref, accounts: nil), [])
    }

    func testMenuOffersCurrentLoginThenEachAccountWithTheSavedOneChecked() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: work.ref, accounts: [work, personal]), [
            .init(label: "Current Login", account: nil, isChecked: false),
            .init(label: "dev@acme.test \u{00B7} Acme", account: work.ref, isChecked: true),
            .init(label: "home", account: personal.ref, isChecked: false),
        ])
    }

    func testMenuChecksOnlyTheSavedOrganizationOfASharedEmail() {
        let checked = ClaudeAccountMenu.entries(saved: workElsewhere.ref, accounts: [work, workElsewhere])
            .filter(\.isChecked).map(\.account)
        XCTAssertEqual(checked, [workElsewhere.ref])
    }

    func testMenuChecksCurrentLoginWhenNothingIsSaved() {
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: nil, accounts: [work]).first?.isChecked, true)
    }

    func testMenuKeepsASavedAccountCswapNoLongerHas() {
        let gone = ClaudeAccountRef(email: "gone@acme.test", organizationUuid: "org-acme")
        XCTAssertEqual(ClaudeAccountMenu.entries(saved: gone, accounts: [work]).last,
                       .init(label: "gone@acme.test (not in cswap)", account: gone, isChecked: true))
    }
}
