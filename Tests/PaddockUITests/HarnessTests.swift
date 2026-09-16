import XCTest

/// Checks the channel every other case rests on and nothing else exercises:
/// the runner is sandboxed, so a connection to `Scripts/e2e.sh`'s control
/// socket is the only way it can reach the process that owns the herdr server.
/// No app is launched here.
final class HarnessTests: XCTestCase {
    func testReseedThroughTheControlSocketRestoresTheSeedLayout() throws {
        let session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
        let ids = session.seedIDs()

        try session.mutate(
            #"{"id":"e2e-dirty","method":"tab.create","params":{"workspace_id":"\#(ids.ws)","label":"dirty"}}"#
        )
        let dirtied = try session.snapshot()
        XCTAssertEqual(
            dirtied.tabCount(inWorkspace: ids.ws), 3,
            "the mutation this test then reseeds away never landed, so the reseed below would prove nothing"
        )

        try session.reseed()

        let reseeded = try session.snapshot()
        XCTAssertEqual(reseeded.tabCount(inWorkspace: ids.ws), 2)
        XCTAssertEqual(reseeded.orderedWorkspaceLabels(), ["seed"])
        // The ids matter as much as the counts: a case written against the
        // seed ids only survives a reseed because herdr numbers a new
        // session's workspaces, tabs and panes from one.
        XCTAssertEqual(reseeded.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2])
        XCTAssertEqual(reseeded.paneIDs(inTab: ids.tabB), [ids.p3])
    }
}
