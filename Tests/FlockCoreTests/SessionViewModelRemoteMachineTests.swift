import XCTest
@testable import FlockCore

/// Records every request and answers each with an empty object.
private actor RecordingClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        return Data("{}".utf8)
    }

    func call(_ method: String) -> [String: JSONValue]? {
        calls.first { $0.method == method }?.params
    }

    var methods: [String] { calls.map(\.method) }
}

/// A machine session's panes live on another Mac, so nothing here may read
/// their folders against this Mac's disk or hand them to local tools.
final class SessionViewModelRemoteMachineTests: XCTestCase {
    private let home = "/Users/acme"

    @MainActor
    private func makeViewModel(
        client: RecordingClient, remote: Bool = true,
        startingFolder: StartingFolderChoice = StartingFolderChoice(folder: .home),
        repoBranches: RepoBranchCache = RepoBranchCache()
    ) -> SessionViewModel {
        let viewModel = SessionViewModel(
            client: client,
            startingFolder: { _ in startingFolder },
            homeDirectory: home,
            repoBranches: repoBranches,
            isRemoteMachine: remote
        )
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"seed","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"},{"workspace_id":"w2","label":"reviews","number":2,"active_tab_id":"w2:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"pane_count":1,"agent_status":"unknown"},{"tab_id":"w2:t1","workspace_id":"w2","label":"1","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"cwd":"/Users/acme/src/app","terminal_id":"term-1"},{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"unknown","revision":0,"cwd":"/Users/acme/src/app"}],"layouts":[]}
        """#
        let snapshot = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        viewModel.update(model: SessionModel(snapshot: snapshot), connection: .live)
        return viewModel
    }

    @MainActor
    func testRemoteSessionReadsNoRepoBranches() async {
        var reads: [String] = []
        let cache = RepoBranchCache { folder in
            reads.append(folder)
            return RepoBranch(repo: "app", branch: "main")
        }
        let viewModel = makeViewModel(client: RecordingClient(), repoBranches: cache)

        let place = viewModel.repoBranches.repoBranch(for: "/Users/acme/src/app")

        XCTAssertEqual(reads, [])
        XCTAssertEqual(place, RepoBranch(repo: "app", branch: nil), "the folder's name stays as a label")
    }

    @MainActor
    func testRemoteSessionLinksNoBoardCards() async {
        let client = RecordingClient()
        let viewModel = makeViewModel(client: client)

        let sections = viewModel.railSections(board: .defaults)
        XCTAssertEqual(sections?.board.map(\.label), [])
        XCTAssertEqual(sections?.workspaces.map(\.label), ["seed", "reviews"])

        let link = FlockOpenLink(folder: "/Users/acme/src/app", repo: "/Users/acme/src/app", label: "MR 1", kind: .shell, run: nil)
        await viewModel.openLink(link, pin: nil, board: .defaults)
        let methods = await client.methods
        XCTAssertFalse(methods.contains("tab.create"))
        XCTAssertFalse(methods.contains("workspace.create"))
    }

    @MainActor
    func testALocalSessionStillLinksBoardWorkspaces() async {
        let viewModel = makeViewModel(client: RecordingClient(), remote: false)

        XCTAssertEqual(viewModel.railSections(board: .defaults)?.board.map(\.label), ["reviews"])
    }

    @MainActor
    func testRemoteSessionOffersNoRt() async {
        let client = RecordingClient()
        let viewModel = makeViewModel(client: client)
        let pane = viewModel.fullModel!.panes[PaneID(rawValue: "w1:p1")]!

        XCTAssertEqual(viewModel.rt.buttonAppearance(linkedTo: pane.terminalID, rtInstalled: true), .absent)
        await viewModel.rt.open(.nav, from: pane)
        let methods = await client.methods
        XCTAssertEqual(methods, [])
    }

    @MainActor
    func testRemoteSessionSendsNoLocalFolderForNewShells() async {
        let client = RecordingClient()
        let viewModel = makeViewModel(client: client, startingFolder: StartingFolderChoice(folder: .mainCheckout))

        await viewModel.createTab(in: WorkspaceID(rawValue: "w1"))
        await viewModel.createWorkspace()
        await viewModel.splitRight(from: PaneID(rawValue: "w1:p1"))

        for method in ["tab.create", "workspace.create", "pane.split"] {
            let params = await client.call(method)
            XCTAssertNotNil(params, method)
            XCTAssertNil(params?["cwd"] ?? nil, method)
        }
        let methods = await client.methods
        XCTAssertFalse(methods.contains("pane.process_info"), "the pane's folder is never needed")
    }

    @MainActor
    func testRemoteStartScreenSendsNoLocalFolder() async {
        let client = RecordingClient()
        let viewModel = makeViewModel(client: client)

        await viewModel.startWorkspace(in: "/Users/acme/src")

        let params = await client.call("workspace.create")
        XCTAssertNotNil(params)
        XCTAssertNil(params?["cwd"] ?? nil)
    }
}
