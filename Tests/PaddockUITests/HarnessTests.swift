import XCTest

/// The harness talking to herdr, with no app involved: the bridge transport,
/// both control verbs, and every ground-truth accessor the drag suites will
/// assert through.
final class HarnessTests: XCTestCase {
    private var session: ScratchSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
    }

    func testGroundTruthReadsTheSeedLayout() throws {
        let ids = session.seedIDs()
        let truth = try session.snapshot()

        XCTAssertEqual(truth.workspaceCount, 1)
        XCTAssertEqual(truth.orderedWorkspaceIDs(), [ids.ws])
        XCTAssertEqual(truth.orderedWorkspaceLabels(), ["seed"])

        XCTAssertEqual(truth.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB])
        XCTAssertEqual(truth.tabCount(inWorkspace: ids.ws), 2)
        XCTAssertEqual(truth.label(ofTab: ids.tabB), "tabB")

        XCTAssertEqual(truth.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2])
        XCTAssertEqual(truth.paneCount(inTab: ids.tabA), 2)
        XCTAssertEqual(truth.paneIDs(inTab: ids.tabB), [ids.p3])
        XCTAssertEqual(truth.paneCount(inTab: ids.tabB), 1)

        XCTAssertEqual(truth.focusedWorkspaceID, ids.ws)
        XCTAssertEqual(truth.focusedTabID, ids.tabA)
        XCTAssertEqual(truth.focusedPaneID, ids.p1)
        XCTAssertFalse(truth.isZoomed(tab: ids.tabA))

        XCTAssertEqual(try XCTUnwrap(truth.layoutRatio(tab: ids.tabA)), 0.5, accuracy: 0.01)
        XCTAssertNil(truth.layoutRatio(tab: ids.tabB), "a single-pane tab has no split to take a ratio from")

        let left = try XCTUnwrap(truth.paneRect(ids.p1))
        let right = try XCTUnwrap(truth.paneRect(ids.p2))
        XCTAssertEqual(left.x + left.width, right.x, "the seed's right split leaves no gap between its two panes")
        XCTAssertEqual(left.width, right.width)
        XCTAssertEqual(left.height, right.height)
        XCTAssertEqual(left.y, right.y)
    }

    func testMutationsLandAndReseedUndoesThem() throws {
        let ids = session.seedIDs()

        try session.mutate(
            #"{"id":"e2e-rename","method":"tab.rename","params":{"tab_id":"\#(ids.tabB)","label":"dirtied"}}"#
        )
        try session.mutate(
            #"{"id":"e2e-newtab","method":"tab.create","params":{"workspace_id":"\#(ids.ws)","label":"extra"}}"#
        )
        let dirtied = try session.snapshot()
        XCTAssertEqual(dirtied.label(ofTab: ids.tabB), "dirtied", "the rename never landed")
        XCTAssertEqual(dirtied.tabCount(inWorkspace: ids.ws), 3, "the tab this test then reseeds away never landed")

        try session.reseed()

        let reseeded = try session.snapshot()
        XCTAssertEqual(reseeded.tabCount(inWorkspace: ids.ws), 2)
        XCTAssertEqual(reseeded.label(ofTab: ids.tabB), "tabB")
        XCTAssertEqual(reseeded.orderedWorkspaceLabels(), ["seed"])
        // The ids matter as much as the counts: a case written against the
        // seed ids only survives a reseed because herdr numbers a new
        // session's workspaces, tabs and panes from one.
        XCTAssertEqual(reseeded.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2])
        XCTAssertEqual(reseeded.paneIDs(inTab: ids.tabB), [ids.p3])
    }

    func testRestartServerBringsTheSessionBackAsItWas() throws {
        let ids = session.seedIDs()
        try session.mutate(
            #"{"id":"e2e-rename","method":"tab.rename","params":{"tab_id":"\#(ids.tabB)","label":"survives"}}"#
        )
        XCTAssertEqual(try session.snapshot().label(ofTab: ids.tabB), "survives")

        try session.restartServer()

        // A restart keeps the session directory, so the difference from a
        // reseed is exactly this: the change made before it is still there.
        let restored = try session.snapshot()
        XCTAssertEqual(restored.label(ofTab: ids.tabB), "survives", "the restart did not restore what the session was holding")
        XCTAssertEqual(restored.tabIDs(inWorkspace: ids.ws), [ids.tabA, ids.tabB])
        XCTAssertEqual(restored.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2])
    }
}
