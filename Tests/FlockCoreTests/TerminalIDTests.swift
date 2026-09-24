import XCTest
@testable import FlockCore

final class TerminalIDTests: XCTestCase {
    func testAPaneRecordCarriesHerdrsTerminalID() throws {
        let json = #"{"pane_id":"w1:p1","terminal_id":"term_18c2f0a1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/src/acme"}"#
        let pane = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        XCTAssertEqual(pane.terminalID, TerminalID(rawValue: "term_18c2f0a1"))
    }

    func testAPaneRecordWithoutOneStillDecodes() throws {
        let json = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/src/acme"}"#
        let pane = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        XCTAssertNil(pane.terminalID)
    }
}
