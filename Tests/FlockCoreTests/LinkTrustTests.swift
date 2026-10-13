import XCTest
@testable import FlockCore

/// Which addresses open without asking. A scheme trusted by mistake hands
/// whatever a pane prints to another app, silently, from then on.
@MainActor
final class LinkTrustTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    private func defaults() throws -> UserDefaults {
        let name = "flock.tests.linkTrust.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheBrowserAndMailAreTrustedFromTheStart() {
        let trust = LinkTrust()
        XCTAssertTrue(trust.trusts(url("https://example.com")))
        XCTAssertTrue(trust.trusts(url("HTTP://example.com")))
        XCTAssertTrue(trust.trusts(url("mailto:sam@example.com")))
    }

    func testAnyOtherSchemeIsNotTrustedUntilItIs() {
        var trust = LinkTrust()
        XCTAssertFalse(trust.trusts(url("vscode://file/Users/acme/notes.md")))
        trust.trust("vscode")
        XCTAssertTrue(trust.trusts(url("vscode://file/Users/acme/notes.md")))
        XCTAssertFalse(trust.trusts(url("ssh://acme.example.com")))
    }

    func testTrustIgnoresCase() {
        var trust = LinkTrust()
        trust.trust("VSCode")
        XCTAssertTrue(trust.trusts(url("vscode://file")))
        XCTAssertTrue(trust.trusts(url("VSCODE://file")))
        XCTAssertEqual(trust.listed, ["vscode"])
    }

    func testRevokingAsksAgain() {
        var trust = LinkTrust(schemes: ["vscode", "ssh"])
        trust.revoke("vscode")
        XCTAssertFalse(trust.trusts(url("vscode://file")))
        XCTAssertEqual(trust.listed, ["ssh"])
    }

    /// Settings lists what can be revoked, and these cannot.
    func testTheBuiltInSchemesAreNeverListed() {
        var trust = LinkTrust(schemes: ["https", "vscode"])
        trust.trust("mailto")
        XCTAssertEqual(trust.listed, ["vscode"])
    }

    func testTheStoreRemembersAcrossLaunches() throws {
        let defaults = try defaults()
        let store = LinkTrustStore(userDefaults: defaults)
        store.trust("vscode")
        store.trust("ssh")
        store.revoke("ssh")
        XCTAssertEqual(LinkTrustStore(userDefaults: defaults).trust.listed, ["vscode"])
    }
}
