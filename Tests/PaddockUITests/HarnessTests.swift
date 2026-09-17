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

    /// The bridge forwards arbitrary herdr requests, and one of them makes a
    /// PTY running a shell, so the token is the only thing between a loopback
    /// port and execution as whoever is running the suite.
    func testBridgeRefusesARequestCarryingTheWrongToken() throws {
        // The same length as the real token, so the comparison itself is what
        // rejects this rather than a length mismatch short-circuiting it.
        let wrong = String(repeating: "0", count: 32)
        let refused = try session.sendRawBridgeLine("\(wrong) ping")
        XCTAssertTrue(refused.contains("bad bridge token"), "the bridge answered an untokened request: \(refused)")

        // A token the comparison cannot even encode still has to come back as
        // a refusal, not as a dead connection.
        let nonASCII = try session.sendRawBridgeLine("t\u{00f8}ken ping")
        XCTAssertTrue(nonASCII.contains("bad bridge token"), "a non-ASCII token did not read as a refusal: \(nonASCII)")

        // The same connection shape with the real token still works, so the
        // refusal above is the token's doing rather than a dead bridge.
        XCTAssertEqual(try session.snapshot().workspaceCount, 1)
    }

    /// The comparison a case asserting "this gesture changed nothing" rests
    /// on. It has to ignore exactly the fields that move with nothing having
    /// touched the session and nothing else, so both halves are checked here:
    /// a self-moving field reads as equal, and an ordinary field one step away
    /// reads as changed.
    func testSnapshotComparisonIgnoresOnlyTheFieldsThatMoveOnTheirOwn() throws {
        let ids = session.seedIDs()
        let truth = try session.snapshot()
        XCTAssertNil(truth.difference(from: truth), "a snapshot did not compare equal to itself")

        let moved = try HerdrSnapshotJSON(Self.byChangingPane(ids.p1, in: truth.raw) { pane in
            var pane = pane
            pane["revision"] = 41
            pane["scroll"] = ["offset_from_bottom": 7, "max_offset_from_bottom": 9, "viewport_rows": 11]
            pane["terminal_id"] = "term_reseeded_something_else"
            return pane
        })
        XCTAssertNil(
            truth.difference(from: moved),
            "revision, scroll and terminal_id move on their own, so a snapshot differing only in them must read as equal"
        )

        let renamed = try HerdrSnapshotJSON(Self.byChangingPane(ids.p1, in: truth.raw) { pane in
            var pane = pane
            pane["cwd"] = "/tmp/somewhere-else"
            return pane
        })
        let reported = try XCTUnwrap(
            truth.difference(from: renamed),
            "a pane's cwd is not a self-moving field, so changing it must read as a difference"
        )
        XCTAssertTrue(
            reported.contains("cwd") && reported.contains(ids.p1),
            "the difference must name the pane and the field that moved, got: \(reported)"
        )
    }

    func testSnapshotComparisonSeesAMutationAndAReseedUndoingIt() throws {
        let ids = session.seedIDs()
        let seeded = try session.snapshot()

        try session.mutate(
            #"{"id":"e2e-compare","method":"tab.rename","params":{"tab_id":"\#(ids.tabB)","label":"moved-on"}}"#
        )
        let dirtied = try session.snapshot(waitingFor: "the rename to land") { $0.label(ofTab: ids.tabB) == "moved-on" }
        let reported = try XCTUnwrap(
            seeded.difference(from: dirtied), "a renamed tab did not read as a difference"
        )
        XCTAssertTrue(reported.contains("label"), "the difference must name the renamed field, got: \(reported)")

        try session.reseed()

        let reseeded = try session.snapshot()
        XCTAssertNil(
            seeded.difference(from: reseeded),
            "a reseeded session must compare equal to the seed it was built from"
        )
    }

    /// One pane of a snapshot's raw JSON, replaced by `change`. Building the
    /// comparison's input by hand is what lets the self-moving fields be
    /// exercised at all: nothing a test can ask herdr to do moves `revision`
    /// without also moving something else.
    private static func byChangingPane(
        _ paneID: String, in raw: [String: Any], _ change: ([String: Any]) -> [String: Any]
    ) throws -> [String: Any] {
        let panes = try XCTUnwrap(raw["panes"] as? [[String: Any]], "the snapshot carries no panes list")
        var copy = raw
        copy["panes"] = panes.map { pane in
            pane["pane_id"] as? String == paneID ? change(pane) : pane
        }
        return copy
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
