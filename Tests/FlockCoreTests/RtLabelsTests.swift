import XCTest
@testable import FlockCore

final class RtLabelsTests: XCTestCase {
    func testTheSharedAndRunnerWorkspacesAreFlockOwnedAndNothingElse() {
        XCTAssertTrue(RtLabels.isFlockOwned(workspaceLabel: "flock:rt"))
        XCTAssertTrue(RtLabels.isFlockOwned(workspaceLabel: "flock:rt runner term_a1"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "acme"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "flock:rtx"))
        XCTAssertFalse(RtLabels.isFlockOwned(workspaceLabel: "my flock:rt"))
    }

    func testARunnerWorkspaceNamesItsTerminal() {
        XCTAssertEqual(RtLabels.runnerWorkspaceLabel(linkedTo: TerminalID(rawValue: "term_a1")), "flock:rt runner term_a1")
    }

    func testATabLabelRoundTrips() {
        let link = RtLabels.TabLink(kind: .run, terminal: TerminalID(rawValue: "term_18c2f0a1"), token: "3f2a")
        XCTAssertEqual(RtLabels.tabLabel(link), "run term_18c2f0a1 3f2a")
        XCTAssertEqual(RtLabels.tabLink(fromLabel: "run term_18c2f0a1 3f2a"), link)
    }

    /// The parser every flock released before pane ids were recorded,
    /// frozen here: one that cannot read a label tears its link down.
    private func olderFlockParse(_ label: String) -> (kind: String, terminal: String, token: String)? {
        let parts = label.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, RtKind(rawValue: parts[0]) != nil, !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return (parts[0], parts[1], parts[2])
    }

    func testEveryLabelThisBuildWritesReadsInAnOlderFlock() throws {
        for kind in RtKind.allCases {
            let label = RtLabels.tabLabel(RtLabels.TabLink(kind: kind, terminal: TerminalID(rawValue: "term_b7"), token: "9c1e"))
            let parsed = try XCTUnwrap(olderFlockParse(label), "an older flock cannot read \(label)")
            XCTAssertEqual(parsed.kind, kind.rawValue)
            XCTAssertEqual(parsed.terminal, "term_b7")
            XCTAssertEqual(parsed.token, "9c1e")
        }
    }

    func testAnythingElseIsNotALink() {
        XCTAssertNil(RtLabels.tabLink(fromLabel: "zsh"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "build term_a1 3f2a"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run  3f2a"))
        XCTAssertNil(RtLabels.tabLink(fromLabel: "run term_a1 3f2a extra"))
    }
}
