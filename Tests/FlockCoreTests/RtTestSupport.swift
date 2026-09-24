import Foundation
@testable import FlockCore

/// A herdr snapshot in plain values: one visible workspace holding the pane
/// every rt test opens from, plus whatever a test or `FakeRtWorld` adds.
struct RtFixture {
    struct Workspace { var id: String; var label: String }
    struct Tab { var id: String; var workspace: String; var label: String; var number: Int }
    struct Pane {
        var id: String; var tab: String; var workspace: String; var terminal: String?; var cwd: String
        var foregroundCwd: String? = nil
    }

    static let linkedPaneID = PaneID(rawValue: "w1:p1")
    static let linkedTerminal = TerminalID(rawValue: "term_a1")

    var workspaces = [Workspace(id: "w1", label: "acme")]
    var tabs = [Tab(id: "w1:t1", workspace: "w1", label: "main", number: 1)]
    var panes = [Pane(id: "w1:p1", tab: "w1:t1", workspace: "w1", terminal: "term_a1", cwd: "/src/acme")]
    var focusedPane: String? = "w1:p1"

    func model() -> SessionModel {
        let workspaceJSON = workspaces.map { workspace -> [String: Any] in
            let active = tabs.first { $0.workspace == workspace.id }?.id ?? "\(workspace.id):t0"
            return ["workspace_id": workspace.id, "label": workspace.label, "number": 1, "active_tab_id": active, "agent_status": "unknown"]
        }
        let tabJSON = tabs.map { tab -> [String: Any] in
            ["tab_id": tab.id, "workspace_id": tab.workspace, "label": tab.label, "number": tab.number,
             "pane_count": panes.filter { $0.tab == tab.id }.count, "agent_status": "unknown"]
        }
        let paneJSON = panes.map { pane -> [String: Any] in
            var json: [String: Any] = [
                "pane_id": pane.id, "workspace_id": pane.workspace, "tab_id": pane.tab,
                "focused": pane.id == focusedPane, "agent_status": "unknown", "revision": 0, "cwd": pane.cwd,
            ]
            if let terminal = pane.terminal { json["terminal_id"] = terminal }
            if let foregroundCwd = pane.foregroundCwd { json["foreground_cwd"] = foregroundCwd }
            return json
        }
        var snapshot: [String: Any] = [
            "version": "0.9.0", "protocol": 22, "workspaces": workspaceJSON, "tabs": tabJSON, "panes": paneJSON, "layouts": [],
        ]
        if let focusedPane, let pane = panes.first(where: { $0.id == focusedPane }) {
            snapshot["focused_pane_id"] = pane.id
            snapshot["focused_tab_id"] = pane.tab
            snapshot["focused_workspace_id"] = pane.workspace
        }
        let data = try! JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: data))
    }

    var linkedPane: PaneRecord { model().panes[Self.linkedPaneID]! }
}

/// herdr and the disk in one. It answers the verbs rt's hidden terminals use,
/// and runs a typed line by a script: busy for so many polls of its pane, then
/// the status and result files the pane's env names are written.
final class FakeRtWorld: HerdrCommandClient, RtFileStore, @unchecked Sendable {
    struct Run {
        var busyPolls: Int
        var status: String?
        var out: String? = nil
        var foreground: [String] = ["bun"]
        /// Busy polls after the files land: a script rt typed into its own pane.
        var afterPolls: Int = 0
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var recorded: [(method: String, params: [String: JSONValue])] = []
    private var stored: [URL: String] = [:]
    private var scripts: [(prefix: String, run: Run)] = []
    private var running: [String: (left: Int, run: Run)] = [:]
    /// A self-launched script: one idle poll (rt gone, the shell not yet on
    /// the typed line), then busy for the rest.
    private var trailing: [String: (idle: Int, busy: Int)] = [:]
    private var confirming: Set<String> = []
    private var envByPane: [String: [String: String]] = [:]
    private var workspaceCounter = 0
    private var tabCounters: [String: Int] = [:]
    private var terminalCounter = 0
    private(set) var fixture = RtFixture()

    var failing: Set<String> = []
    var silentPanes: Set<String> = []
    /// Fail the next `process_info` for these panes, once each.
    var silentOnce: Set<String> = []
    var busyPanes: Set<String> = []
    /// The folder a busy pane's foreground processes report. An idle pane's
    /// shell reports the pane's own `cwd`.
    var processCwds: [String: String] = [:]
    var shell = "zsh"

    var calls: [(method: String, params: [String: JSONValue])] { locked { recorded } }

    func calls(_ method: String) -> [[String: JSONValue]] { calls.filter { $0.method == method }.map(\.params) }

    func typed(into pane: String) -> [String] {
        calls("pane.send_input").filter { Self.string($0["pane_id"]) == pane }.compactMap { Self.string($0["text"]) }
    }

    func script(_ prefix: String, _ run: Run) { locked { scripts.append((prefix, run)) } }

    func write(_ text: String, to url: URL) { locked { stored[url] = text } }

    /// Adds entities as if herdr already had them, for launch-time tests.
    func seed(workspace: String, label: String) { locked { fixture.workspaces.append(.init(id: workspace, label: label)) } }

    func seed(tab: String, in workspace: String, label: String, number: Int) {
        locked { fixture.tabs.append(.init(id: tab, workspace: workspace, label: label, number: number)) }
    }

    func seed(pane: String, tab: String, workspace: String, terminal: String) {
        locked { fixture.panes.append(.init(id: pane, tab: tab, workspace: workspace, terminal: terminal, cwd: "/src/acme")) }
    }

    func removeLinkedPane() { locked { fixture.panes.removeAll { $0.id == "w1:p1" } } }

    func moveLinkedPane(to newID: String) {
        locked {
            if let index = fixture.panes.firstIndex(where: { $0.id == "w1:p1" }) { fixture.panes[index].id = newID }
        }
    }

    func stripTerminals() {
        locked { for index in fixture.panes.indices { fixture.panes[index].terminal = nil } }
    }

    func focus(_ pane: String?) { locked { fixture.focusedPane = pane } }

    func setForegroundCwd(_ cwd: String?, of pane: String) {
        locked {
            if let index = fixture.panes.firstIndex(where: { $0.id == pane }) { fixture.panes[index].foregroundCwd = cwd }
        }
    }

    func model() -> SessionModel { locked { fixture.model() } }

    // MARK: RtFileStore

    func read(_ url: URL) -> String? { locked { stored[url] } }
    func delete(_ url: URL) { locked { stored[url] = nil } }
    func prepareDirectory(_ url: URL) {}

    // MARK: HerdrCommandClient

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        try locked { try answer(method, params) }
    }

    private func answer(_ method: String, _ params: [String: JSONValue]) throws -> Data {
        recorded.append((method, params))
        if failing.contains(method) { throw Failure() }
        switch method {
        case "workspace.create":
            workspaceCounter += 1
            let workspace = "wF\(workspaceCounter)"
            fixture.workspaces.append(.init(id: workspace, label: Self.string(params["label"]) ?? ""))
            return createTab(in: workspace, label: "zsh", params: params)
        case "tab.create":
            return createTab(in: Self.string(params["workspace_id"]) ?? "", label: Self.string(params["label"]) ?? "zsh", params: params)
        case "tab.rename":
            if let id = Self.string(params["tab_id"]), let index = fixture.tabs.firstIndex(where: { $0.id == id }) {
                fixture.tabs[index].label = Self.string(params["label"]) ?? ""
            }
        case "tab.close":
            let id = Self.string(params["tab_id"])
            fixture.tabs.removeAll { $0.id == id }
            fixture.panes.removeAll { $0.tab == id }
        case "workspace.close":
            let id = Self.string(params["workspace_id"])
            fixture.workspaces.removeAll { $0.id == id }
            fixture.tabs.removeAll { $0.workspace == id }
            fixture.panes.removeAll { $0.workspace == id }
        case "pane.send_input":
            let pane = Self.string(params["pane_id"]) ?? ""
            let text = Self.string(params["text"]) ?? ""
            if let index = scripts.firstIndex(where: { text.hasPrefix($0.prefix) }) {
                let run = scripts.remove(at: index).run
                if run.busyPolls == 0 { finish(pane, run) } else { running[pane] = (run.busyPolls, run) }
            }
        case "pane.send_keys":
            let pane = Self.string(params["pane_id"]) ?? ""
            let keys = Self.strings(params["keys"])
            if keys == ["ctrl+c"], let state = running[pane] {
                if state.run.foreground.contains("rt-ui") {
                    confirming.insert(pane)
                } else {
                    running[pane] = nil
                    finish(pane, Run(busyPolls: 0, status: "130"))
                }
            } else if keys == ["y"], confirming.remove(pane) != nil {
                running[pane] = nil
                finish(pane, Run(busyPolls: 0, status: "0"))
            }
        case "pane.process_info":
            let pane = Self.string(params["pane_id"]) ?? ""
            if silentPanes.contains(pane) || silentOnce.remove(pane) != nil { throw Failure() }
            var busy = busyPanes.contains(pane)
            var names = ["claude"]
            if var state = running[pane] {
                busy = true
                names = state.run.foreground
                state.left -= 1
                if state.left <= 0, !confirming.contains(pane) {
                    running[pane] = nil
                    finish(pane, state.run)
                } else {
                    running[pane] = state
                }
            } else if let tail = trailing[pane] {
                if tail.idle > 0 {
                    trailing[pane] = (tail.idle - 1, tail.busy)
                } else if tail.busy > 0 {
                    busy = true
                    trailing[pane] = (0, tail.busy - 1)
                } else {
                    trailing[pane] = nil
                }
            }
            let cwd = busy ? processCwds[pane] : fixture.panes.first(where: { $0.id == pane })?.cwd
            return Self.processInfo(pane: pane, busy: busy, names: names, shell: shell, cwd: cwd)
        default:
            break
        }
        return Data("{}".utf8)
    }

    /// Tabs and panes are numbered within their workspace, so a workspace's
    /// first tab is always `<workspace>:t1` holding `<workspace>:p1`.
    private func createTab(in workspace: String, label: String, params: [String: JSONValue]) -> Data {
        let number = (tabCounters[workspace] ?? 0) + 1
        tabCounters[workspace] = number
        terminalCounter += 1
        let tab = "\(workspace):t\(number)"
        let pane = "\(workspace):p\(number)"
        let terminal = "term_\(terminalCounter)"
        fixture.tabs.append(.init(id: tab, workspace: workspace, label: label, number: number))
        fixture.panes.append(.init(id: pane, tab: tab, workspace: workspace, terminal: terminal, cwd: Self.string(params["cwd"]) ?? "/"))
        if case .object(let env) = params["env"] {
            envByPane[pane] = env.compactMapValues(Self.string)
        }
        return Data(#"{"result":{"type":"tab_created","tab":{"tab_id":"\#(tab)","workspace_id":"\#(workspace)"},"root_pane":{"pane_id":"\#(pane)","terminal_id":"\#(terminal)"}}}"#.utf8)
    }

    private func finish(_ pane: String, _ run: Run) {
        let env = envByPane[pane] ?? [:]
        if let status = run.status, let path = env["FLOCK_RT_STATUS"] { stored[URL(fileURLWithPath: path)] = status + "\n" }
        if let out = run.out, let path = env["FLOCK_RT_OUT"] { stored[URL(fileURLWithPath: path)] = out }
        if run.afterPolls > 0 { trailing[pane] = (idle: 1, busy: run.afterPolls) }
    }

    private static func processInfo(pane: String, busy: Bool, names: [String], shell: String, cwd: String?) -> Data {
        let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
        let processes = busy
            ? names.enumerated().map { #"{"name":"\#($0.element)","pid":\#(731 + $0.offset)\#(cwdField)}"# }.joined(separator: ",")
            : #"{"name":"\#(shell)","pid":500\#(cwdField)}"#
        let group = busy ? 731 : 500
        return Data(#"{"result":{"process_info":{"pane_id":"\#(pane)","shell_pid":500,"foreground_process_group_id":\#(group),"foreground_processes":[\#(processes)]}}}"#.utf8)
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let values) = value { return values.compactMap(string) }
        return []
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@MainActor
final class TokenSource {
    private var tokens: [String]
    init(_ tokens: [String]) { self.tokens = tokens }
    func next() -> String { tokens.isEmpty ? UUID().uuidString : tokens.removeFirst() }
}

@MainActor
func makeCoordinator(_ world: FakeRtWorld, tokens: [String] = ["tok1", "tok2", "tok3"], notices: NoticeLog? = nil) -> RtCoordinator {
    let source = TokenSource(tokens)
    return RtCoordinator(
        client: world, files: world,
        config: .init(
            pollInterval: .milliseconds(1), confirmDelay: .milliseconds(5), shutdownTimeout: .milliseconds(500),
            shellWait: .milliseconds(20), missLimit: 3, fileDirectory: rtTestDirectory
        ),
        makeToken: { source.next() },
        notice: { notices?.lines.append($0) }
    )
}

let rtTestDirectory = URL(fileURLWithPath: "/flock-rt-test", isDirectory: true)

func rtPaths(_ token: String) -> RtFilePaths { RtFilePaths(token: token, directory: rtTestDirectory) }

@MainActor
final class NoticeLog {
    var lines: [String] = []
}

let rtResultLine = #"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"#
let rtSeedLine = #"{"seed":[{"name":"dev","command":"pnpm run dev","cwd":"/src/acme/web","pkg":"web","repo":"acme"}]}"#
