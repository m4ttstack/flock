import XCTest
@testable import FlockCore

/// Answers `pane.process_info` with a shell at its prompt in `leaderCwd`
/// (herdr 0.9's `PaneProcessInfo` shape), or fails it when `leaderCwd` is
/// nil; every other method gets an empty answer.
private actor FolderClient: HerdrCommandClient {
    struct Failure: Error {}

    private(set) var calls: [(method: String, params: [String: JSONValue])] = []
    private let leaderCwd: String?

    init(leaderCwd: String?) {
        self.leaderCwd = leaderCwd
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        guard method == "pane.process_info" else { return Data("{}".utf8) }
        guard let leaderCwd else { throw Failure() }
        return Data(#"""
        {"result":{"process_info":{"pane_id":"w1:p1","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"zsh","pid":500,"cwd":"\#(leaderCwd)"}]},"type":"pane_process_info"}}
        """#.utf8)
    }

    func call(_ method: String) -> [String: JSONValue]? {
        calls.first { $0.method == method }?.params
    }

    func count(_ method: String) -> Int {
        calls.filter { $0.method == method }.count
    }
}

@MainActor
final class StartingFolderCreateTests: XCTestCase {
    private let home = "/Users/acme"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starting-folder-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A main checkout at `acme` and a linked worktree of it at `trees/wt`.
    private func makeRepoAndWorktree() throws -> (repo: String, worktree: String) {
        let repo = root.appendingPathComponent("acme")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try "../..\n".write(to: repo.appendingPathComponent(".git/worktrees/wt/commondir"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("trees/wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo.appendingPathComponent(".git/worktrees/wt").path)\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return (repo.path, worktree.path)
    }

    private func makeViewModel(
        client: FolderClient, _ choices: [NewTerminalKind: StartingFolderChoice], paneCwd: String = "/tmp"
    ) -> SessionViewModel {
        let viewModel = SessionViewModel(
            client: client,
            startingFolder: { choices[$0] ?? StartingFolderChoice(folder: .currentPane) },
            homeDirectory: home
        )
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"\#(paneCwd)"}],"layouts":[]}
        """#
        let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        viewModel.update(model: SessionModel(snapshot: snapshot), connection: .live)
        return viewModel
    }

    private func string(_ params: [String: JSONValue]?, _ key: String) -> String? {
        guard case .string(let value)? = params?[key] else { return nil }
        return value
    }

    private func cwd(_ params: [String: JSONValue]?) -> String? {
        string(params, "cwd")
    }

    func testANewTabFromAWorktreeStartsInTheMainCheckout() async throws {
        let (repo, worktree) = try makeRepoAndWorktree()
        let client = FolderClient(leaderCwd: worktree)
        let viewModel = makeViewModel(client: client, [.tab: StartingFolderChoice(folder: .mainCheckout)])

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))

        let processInfo = await client.call("pane.process_info")
        XCTAssertEqual(string(processInfo, "pane_id"), "w1:p1", "the folder is the focused pane's")
        let created = await client.call("tab.create")
        XCTAssertEqual(cwd(created), repo)
    }

    func testFollowingThePaneSendsNoFolderAndAsksHerdrNothing() async throws {
        let client = FolderClient(leaderCwd: "/Users/acme/code")
        let viewModel = makeViewModel(client: client, [:])

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))
        await viewModel.createWorkspace()
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))

        for method in ["tab.create", "workspace.create", "pane.split"] {
            let params = await client.call(method)
            XCTAssertNotNil(params, method)
            XCTAssertNil(params?["cwd"] ?? nil, "\(method) leaves the folder to herdr")
        }
        let processInfoCalls = await client.count("pane.process_info")
        XCTAssertEqual(processInfoCalls, 0)
    }

    func testANewPaneSetToHomeStartsAtHome() async throws {
        let client = FolderClient(leaderCwd: "/Users/acme/code")
        let viewModel = makeViewModel(client: client, [.pane: StartingFolderChoice(folder: .home)])

        await viewModel.splitDown(from: PaneID(rawValue: "w1:p1"))

        let split = await client.call("pane.split")
        XCTAssertEqual(cwd(split), home)
        let processInfoCalls = await client.count("pane.process_info")
        XCTAssertEqual(processInfoCalls, 0, "home needs no pane folder")
    }

    func testANewWorkspaceSetToACustomFolderStartsThere() async throws {
        let client = FolderClient(leaderCwd: "/Users/acme/code")
        let viewModel = makeViewModel(client: client, [.workspace: StartingFolderChoice(folder: .custom, customPath: root.path)])

        await viewModel.createWorkspace()

        let created = await client.call("workspace.create")
        XCTAssertEqual(cwd(created), root.path)
    }

    func testASplitReadsTheFolderOfThePaneItSplits() async throws {
        let (repo, worktree) = try makeRepoAndWorktree()
        let client = FolderClient(leaderCwd: worktree)
        let viewModel = makeViewModel(client: client, [.pane: StartingFolderChoice(folder: .mainCheckout)])

        await viewModel.splitRight(from: PaneID(rawValue: "w1:p9"))

        let processInfo = await client.call("pane.process_info")
        XCTAssertEqual(string(processInfo, "pane_id"), "w1:p9")
        let split = await client.call("pane.split")
        XCTAssertEqual(cwd(split), repo)
    }

    func testWhenHerdrCannotSayThePanesRecordedFolderIsUsed() async throws {
        let (repo, worktree) = try makeRepoAndWorktree()
        let client = FolderClient(leaderCwd: nil)
        let viewModel = makeViewModel(client: client, [.tab: StartingFolderChoice(folder: .mainCheckout)], paneCwd: worktree)

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))

        let created = await client.call("tab.create")
        XCTAssertEqual(cwd(created), repo)
    }
}
