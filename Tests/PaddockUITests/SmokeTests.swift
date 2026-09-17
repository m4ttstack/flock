import XCTest

/// Launches the app against a herdr session it did not create and checks that
/// the canvas, strip and rail hold what herdr holds.
final class SmokeTests: XCTestCase {
    private var session: ScratchSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
    }

    /// Longer than this case can possibly run. The wrapper gives the suite a
    /// two-second re-snapshot interval, under which a broken initial mirror
    /// would be repaired by the next periodic replacement and every wait below
    /// would still succeed; with the backstop pushed out of reach, the only
    /// things that can produce the layout are the bootstrap fetch and the
    /// event stream.
    private static let noResnapshotWithin = "600"

    @MainActor
    func testAppMirrorsSeedLayout() throws {
        let ids = session.seedIDs()
        // Read before the app exists, so every assertion below is against a
        // layout herdr is holding rather than against whatever the app drew.
        let truth = try session.snapshot()
        XCTAssertEqual(truth.orderedWorkspaceLabels(), ["seed"])
        XCTAssertEqual(truth.tabCount(inWorkspace: ids.ws), 2)
        XCTAssertEqual(truth.paneIDs(inTab: ids.tabA), [ids.p1, ids.p2])
        XCTAssertEqual(truth.paneIDs(inTab: ids.tabB), [ids.p3])
        XCTAssertEqual(truth.focusedTabID, ids.tabA)
        XCTAssertEqual(try XCTUnwrap(truth.layoutRatio(tab: ids.tabA)), 0.5, accuracy: 0.01)

        // Registered before the launch that needs it, and capturing nothing:
        // an assertion failure under `continueAfterFailure = false` unwinds
        // this method through Objective-C, where a `defer` is not reliable,
        // and an app left attached to a session the wrapper is about to stop
        // outlives the whole run.
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.paddock(
            socket: session.socketPath,
            env: ["PADDOCK_RESNAPSHOT_SECONDS": Self.noResnapshotWithin]
        )

        let p1 = app.paddockElement("paddock.canvas.pane.\(ids.p1)")
        XCTAssertTrue(p1.waitForExistence(timeout: 60), "the canvas never showed \(ids.p1)")
        let p2 = app.paddockElement("paddock.canvas.pane.\(ids.p2)")
        XCTAssertTrue(p2.waitForExistence(timeout: 30), "the canvas never showed \(ids.p2)")
        XCTAssertTrue(
            app.paddockElement("paddock.rail.workspace.\(ids.ws)").waitForExistence(timeout: 30),
            "the rail never showed the seed workspace \(ids.ws)"
        )
        XCTAssertTrue(
            app.paddockElement("paddock.strip.tab.\(ids.tabA)").waitForExistence(timeout: 30),
            "the strip never showed \(ids.tabA)"
        )
        XCTAssertTrue(app.paddockElement("paddock.strip.tab.\(ids.tabB)").exists, "the strip never showed \(ids.tabB)")

        // tabB is the seed's unfocused tab, so its pane belongs to no visible
        // cell.
        XCTAssertFalse(
            app.paddockElement("paddock.canvas.pane.\(ids.p3)").exists,
            "\(ids.p3) is in the tab that is not shown, so the canvas must not hold a cell for it"
        )
        XCTAssertEqual(
            app.paddockElementCount(identifierPrefix: "paddock.canvas.pane."), truth.paneCount(inTab: ids.tabA),
            "the canvas holds a different number of cells than the shown tab has panes"
        )

        // The seed splits right, so p1 sits entirely left of p2 with their
        // tops level. A canvas that ignored the split would stack, overlap or
        // reverse them.
        XCTAssertGreaterThan(p1.frame.width, 0, "p1's cell has no width")
        XCTAssertLessThanOrEqual(p1.frame.maxX, p2.frame.minX + 1, "p1's cell is not left of p2's")
        XCTAssertEqual(p1.frame.minY, p2.frame.minY, accuracy: 2, "the two cells of a right split are not level")
        XCTAssertEqual(p1.frame.height, p2.frame.height, accuracy: 2, "the two cells of a right split differ in height")
    }

    /// The app keeps mirroring a session that changes under it. The wrapper
    /// runs the whole suite with `PADDOCK_RESNAPSHOT_SECONDS` set, so this
    /// also covers the app reading it; the interval's own effect on the
    /// re-snapshot cadence is not observable from here.
    @MainActor
    func testAppConvergesOnAnExternalSplit() throws {
        let ids = session.seedIDs()
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.paddock(socket: session.socketPath)
        XCTAssertTrue(
            app.paddockElement("paddock.canvas.pane.\(ids.p1)").waitForExistence(timeout: 60),
            "the canvas never showed \(ids.p1)"
        )

        try session.mutate(
            #"{"id":"e2e-split","method":"pane.split","params":{"target_pane_id":"\#(ids.p1)","direction":"down"}}"#
        )
        let after = try session.snapshot()
        let added = try XCTUnwrap(
            after.paneIDs(inTab: ids.tabA).first { $0 != ids.p1 && $0 != ids.p2 },
            "the split this test asserts on never landed in herdr"
        )

        XCTAssertTrue(
            app.paddockElement("paddock.canvas.pane.\(added)").waitForExistence(timeout: 20),
            "the canvas never showed \(added), which herdr added while the app was already running"
        )
        XCTAssertEqual(
            app.paddockElementCount(identifierPrefix: "paddock.canvas.pane."), 3,
            "the canvas did not settle on the three panes the shown tab now has"
        )
    }
}
