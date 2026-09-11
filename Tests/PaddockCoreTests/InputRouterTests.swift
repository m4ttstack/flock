import XCTest
@testable import PaddockCore

/// Waits (bounded) for `server` to have recorded at least `count` requests
/// for `method` -- `InputRouter` dispatches its wire calls from a detached
/// `Task`, so a test observing `FakeHerdrServer.receivedRequests` right after
/// calling into the router would otherwise race the real socket round trip.
private func waitForRequests(
    _ server: FakeHerdrServer, method: String, count: Int, timeout: TimeInterval = 2.0
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if server.receivedRequests.filter({ $0.method == method }).count >= count { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func paramsDict(_ paramsJSON: String) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any])
}

final class InputRouterTests: XCTestCase {
    @MainActor
    func testBatchesPlainCharactersThenFlushesOnNamedKeyPreservingOrder() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.send_input", withResultJSON: "{}")
        let router = InputRouter(client: HerdrClient(socketPath: server.socketPath), paneID: PaneID(rawValue: "w1:p1"))

        router.typeCharacter("l")
        router.typeCharacter("s")
        router.sendKey(.enter)

        await waitForRequests(server, method: "pane.send_input", count: 2)

        let calls = server.receivedRequests.filter { $0.method == "pane.send_input" }
        XCTAssertEqual(calls.count, 2, "no debounce-timer flush should double up with the key-triggered one")

        let firstParams = try paramsDict(calls[0].paramsJSON)
        XCTAssertEqual(firstParams["pane_id"] as? String, "w1:p1")
        XCTAssertEqual(firstParams["text"] as? String, "ls", "the batched characters flush as one text call")

        let secondParams = try paramsDict(calls[1].paramsJSON)
        XCTAssertEqual(secondParams["keys"] as? [String], ["enter"], "the key follows the flushed text, not before it")
    }

    /// The brief describes ctrl-combos as `"ctrl-<char>"`, but herdr's real
    /// wire parser (`app/api_helpers.rs`'s `normalize_api_key_alias` feeding
    /// `config/keybinds.rs`'s `parse_key_combo`, which splits strictly on
    /// `+`) only recognizes `"ctrl+<char>"` -- the hyphen form matches
    /// neither the hard-coded `"C-c"`/`"c-c"` alias nor the general modifier
    /// grammar, so a real server would reject it `invalid_key`. This test
    /// pins the verified, actually-functional wire string.
    @MainActor
    func testControlComboMapsToPlusJoinedKeyString() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.send_input", withResultJSON: "{}")
        let router = InputRouter(client: HerdrClient(socketPath: server.socketPath), paneID: PaneID(rawValue: "w1:p1"))

        router.sendControlCombo("c")

        await waitForRequests(server, method: "pane.send_input", count: 1)

        let calls = server.receivedRequests.filter { $0.method == "pane.send_input" }
        XCTAssertEqual(calls.count, 1)
        let params = try paramsDict(calls[0].paramsJSON)
        XCTAssertEqual(params["keys"] as? [String], ["ctrl+c"])
    }

    @MainActor
    func testKeystrokesWhileRenamingAreDropped() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.send_input", withResultJSON: "{}")
        let router = InputRouter(client: HerdrClient(socketPath: server.socketPath), paneID: PaneID(rawValue: "w1:p1"))
        router.isRenaming = true

        router.typeCharacter("x")
        router.sendKey(.enter)
        router.sendControlCombo("c")

        // No positive wait possible for "never arrives"; a short grace
        // period is the best a test can do, matching the brief's own
        // "dropped" framing (never sent, not merely delayed).
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(server.receivedRequests.filter { $0.method == "pane.send_input" }.count, 0)
    }

    @MainActor
    func testDragLiveAlsoDropsKeystrokes() async throws {
        let server = FakeHerdrServer(); try server.start(); defer { server.stop() }
        server.respond(to: "pane.send_input", withResultJSON: "{}")
        let router = InputRouter(client: HerdrClient(socketPath: server.socketPath), paneID: PaneID(rawValue: "w1:p1"))
        router.isDragLive = true

        router.typeCharacter("x")
        router.sendKey(.enter)

        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(server.receivedRequests.filter { $0.method == "pane.send_input" }.count, 0)
    }
}

/// The new-pane harness launcher's pristine state machine, tested standalone
/// (no herdr server needed -- it is pure bookkeeping over pane ids).
final class PaneLauncherRegistryTests: XCTestCase {
    @MainActor
    func testPristineShowsOnlyAfterPaddockCreatesThePane() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        XCTAssertFalse(registry.isPristine(pane), "not paddock-created yet")

        registry.registerPaddockCreated(pane)
        XCTAssertTrue(registry.isPristine(pane))
    }

    @MainActor
    func testFirstKeystrokeHidesPermanently() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerPaddockCreated(pane)

        registry.recordKeystroke(pane)
        XCTAssertFalse(registry.isPristine(pane))

        // Permanent: a later "still just the prompt" screen read must not
        // resurrect it.
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1)
        XCTAssertFalse(registry.isPristine(pane))
    }

    @MainActor
    func testOutputBeyondPromptHidesPermanently() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p2")
        registry.registerPaddockCreated(pane)

        registry.recordScreenActivity(pane, nonEmptyRowCount: 2)
        XCTAssertTrue(registry.isPristine(pane), "at most 2 non-empty rows is still just the bare prompt")

        registry.recordScreenActivity(pane, nonEmptyRowCount: 3)
        XCTAssertFalse(registry.isPristine(pane), "output beyond the prompt rows hides it for good")
    }

    @MainActor
    func testHerdrCreatedPanesNeverShow() {
        let registry = PaneLauncherRegistry()
        let pane = PaneID(rawValue: "w1:p9")
        // Never registered via `registerPaddockCreated` -- a pane herdr
        // itself created (not through paddock's split/tab/workspace verbs).
        XCTAssertFalse(registry.isPristine(pane))
        registry.recordScreenActivity(pane, nonEmptyRowCount: 1)
        XCTAssertFalse(registry.isPristine(pane))
    }
}
