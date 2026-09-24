import XCTest
@testable import FlockCore

private actor RecordingRtClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    let answers: [String: String]

    init(answers: [String: String] = [:]) {
        self.answers = answers
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        return Data((answers[method] ?? "{}").utf8)
    }
}

private func string(_ value: JSONValue?) -> String? {
    if case .string(let text) = value { return text }
    return nil
}

private func bool(_ value: JSONValue?) -> Bool? {
    if case .bool(let flag) = value { return flag }
    return nil
}

final class RtHerdrTests: XCTestCase {
    private let created = #"{"result":{"type":"tab_created","tab":{"tab_id":"wF:t2","workspace_id":"wF"},"root_pane":{"pane_id":"wF:p2","terminal_id":"term_f2"}}}"#

    func testATabIsCreatedHiddenLabelledAndCarryingItsEnv() async throws {
        let client = RecordingRtClient(answers: ["tab.create": created])
        let herdr = RtHerdr(client: client)

        let made = try await herdr.createTab(
            in: WorkspaceID(rawValue: "wF"), label: "nav term_a1 tok1", cwd: "/src/acme",
            env: ["FLOCK_RT_OUT": "/tmp/flock-rt/tok1.out"]
        )

        XCTAssertEqual(made, RtHerdr.Created(workspaceID: WorkspaceID(rawValue: "wF"), tabID: TabID(rawValue: "wF:t2"), rootPaneID: PaneID(rawValue: "wF:p2")))
        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "tab.create")
        XCTAssertEqual(string(call.params["label"]), "nav term_a1 tok1")
        XCTAssertEqual(string(call.params["cwd"]), "/src/acme")
        XCTAssertEqual(bool(call.params["focus"]), false)
        guard case .object(let env) = call.params["env"] else { return XCTFail("no env") }
        XCTAssertEqual(string(env["FLOCK_RT_OUT"]), "/tmp/flock-rt/tok1.out")
    }

    func testAnAnswerWithoutTheCreatedIdsThrows() async {
        let herdr = RtHerdr(client: RecordingRtClient(answers: ["workspace.create": "{}"]))
        do {
            _ = try await herdr.createWorkspace(label: "flock:rt", cwd: "/src/acme", env: [:])
            XCTFail("expected a throw")
        } catch {}
    }

    func testTypingSubmitsWithAnEnterKey() async throws {
        let client = RecordingRtClient()
        try await RtHerdr(client: client).type("command rt glitter", into: PaneID(rawValue: "wF:p2"))

        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "pane.send_input")
        XCTAssertEqual(string(call.params["text"]), "command rt glitter")
        guard case .array(let keys) = call.params["keys"] else { return XCTFail("no keys") }
        XCTAssertEqual(keys.compactMap(string), ["Enter"])
    }

    func testKeysGoAsKeysNeverText() async throws {
        let client = RecordingRtClient()
        try await RtHerdr(client: client).sendKeys(["y"], to: PaneID(rawValue: "wR:p1"))

        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "pane.send_keys")
        guard case .array(let keys) = call.params["keys"] else { return XCTFail("no keys") }
        XCTAssertEqual(keys.compactMap(string), ["y"])
    }

    func testAPaneStateComesFromProcessInfo() async {
        let answer = #"{"result":{"process_info":{"pane_id":"wF:p2","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"zsh","pid":500}]}}}"#
        let herdr = RtHerdr(client: RecordingRtClient(answers: ["pane.process_info": answer]))
        let state = await herdr.paneState(PaneID(rawValue: "wF:p2"))
        XCTAssertEqual(state?.busy, false)
        XCTAssertEqual(state?.shellName, "zsh")
    }

    func testASplitOpensRightAtTheFolderAndTakesFocus() async throws {
        let client = RecordingRtClient()
        try await RtHerdr(client: client).split(PaneID(rawValue: "w1:p1"), cwd: "/src/acme/web")

        let calls = await client.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "pane.split")
        XCTAssertEqual(string(call.params["target_pane_id"]), "w1:p1")
        XCTAssertEqual(string(call.params["direction"]), "right")
        XCTAssertEqual(string(call.params["cwd"]), "/src/acme/web")
        XCTAssertEqual(bool(call.params["focus"]), true)
    }
}
