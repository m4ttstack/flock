import XCTest

/// Step 2: gesture -> herdr pane.move -> snapshot assertion, unattended.
///
/// The scratch herdr SERVER is started by run-closed-loop.sh, outside the
/// sandboxed test runner (see ScratchHerdrSession.attach and FINDINGS.md).
/// This test only ATTACHES to it via env vars the wrapper exports, then
/// drives its own client-only connections from there.
final class ClosedLoopUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDragFiresHerdrPaneMoveAndSnapshotSeesNewTab() throws {
        let env = ProcessInfo.processInfo.environment
        guard let socketPath = env["SPIKE_SCRATCH_SOCKET"],
              let ws = env["SPIKE_WS_ID"],
              let p1 = env["SPIKE_P1_ID"] else {
            throw SpikeError("SPIKE_SCRATCH_SOCKET / SPIKE_WS_ID / SPIKE_P1_ID not set -- run via run-closed-loop.sh, not xcodebuild directly")
        }
        let session = ScratchHerdrSession.attach(socketPath: socketPath, sessionName: env["SPIKE_SESSION_NAME"] ?? "unknown")
        let before = try session.tabCount(workspaceID: ws)

        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SOCKET_PATH"] = socketPath
        app.launchEnvironment["SPIKE_PANE_ID"] = p1
        app.launchEnvironment["SPIKE_WS_ID"] = ws
        app.launch()

        let source = app.otherElements["spike.drag.source"]
        let target = app.otherElements["spike.drag.target"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), "source element never appeared")
        XCTAssertTrue(target.waitForExistence(timeout: 5), "target element never appeared")

        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.3, thenDragTo: to)

        // The app's herdr call happens off its main thread; poll this test's
        // own connection for the tab count to grow rather than sleeping a
        // fixed guess.
        let deadline = Date().addingTimeInterval(5)
        var after = before
        while Date() < deadline {
            after = try session.tabCount(workspaceID: ws)
            if after > before { break }
            usleep(100_000)
        }

        XCTAssertEqual(after, before + 1, "expected the drag to fire pane.move -> new_tab, growing the workspace's tab count by 1")
    }
}
