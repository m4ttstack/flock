import XCTest
@testable import FlockCore

private actor RecordingClient: HerdrCommandClient {
    private(set) var calls: [(method: String, params: [String: JSONValue])] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        return Data("{}".utf8)
    }

    func call(_ method: String) -> [String: JSONValue]? {
        calls.first { $0.method == method }?.params
    }
}

final class StartScreenTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.start-screen-tests"
    private let home = "/Users/acme"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func model(workspaces: [WorkspaceID]) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: workspaces.first, focusedTabID: workspaces.first.map { TabID(rawValue: "\($0.rawValue):t1") },
            focusedPaneID: nil,
            workspaces: workspaces.enumerated().map { index, id in
                WorkspaceRecord(
                    workspaceID: id, label: "acme", number: index + 1,
                    activeTabID: TabID(rawValue: "\(id.rawValue):t1"), agentStatus: .idle
                )
            },
            tabs: workspaces.map { id in
                TabRecord(tabID: TabID(rawValue: "\(id.rawValue):t1"), workspaceID: id, label: "zsh", number: 1, paneCount: 1, agentStatus: .idle)
            },
            panes: [],
            layouts: []
        ))
    }

    // MARK: - when it shows

    @MainActor
    func testAServerWithNoWorkspacesShowsTheStartScreen() {
        let viewModel = SessionViewModel(client: RecordingClient())
        XCTAssertFalse(viewModel.showsStartScreen, "nothing is known before herdr answers")
        viewModel.update(model: model(workspaces: []), connection: .live)
        XCTAssertTrue(viewModel.showsStartScreen)
        viewModel.update(model: model(workspaces: [WorkspaceID(rawValue: "w1")]), connection: .live)
        XCTAssertFalse(viewModel.showsStartScreen)
    }

    // MARK: - its folder

    @MainActor
    func testANewUserStartsAtHome() throws {
        let store = StartingFolderStore(userDefaults: try makeDefaults())
        XCTAssertEqual(store.startScreenFolder(home: home), home)
    }

    @MainActor
    func testTheFolderLastPickedThereIsOfferedNextSession() throws {
        let defaults = try makeDefaults()
        StartingFolderStore(userDefaults: defaults).pickStartScreenFolder(root.path)
        XCTAssertEqual(StartingFolderStore(userDefaults: defaults).startScreenFolder(home: home), root.path)
    }

    @MainActor
    func testALastPickThatIsGoneFallsBackToHome() throws {
        let defaults = try makeDefaults()
        StartingFolderStore(userDefaults: defaults).pickStartScreenFolder(root.appendingPathComponent("gone").path)
        XCTAssertEqual(StartingFolderStore(userDefaults: defaults).startScreenFolder(home: home), home)
    }

    @MainActor
    func testNextSessionTheNewWorkspaceSettingOutranksTheLastPickForHomeAndCustom() throws {
        let defaults = try makeDefaults()
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        StartingFolderStore(userDefaults: defaults).pickStartScreenFolder(root.path)
        let store = StartingFolderStore(userDefaults: defaults)

        store.select(.home, for: .workspace)
        XCTAssertEqual(store.startScreenFolder(home: home), home)
        store.selectCustom(path: custom.path, for: .workspace)
        XCTAssertEqual(store.startScreenFolder(home: home), custom.path)
        store.select(.mainCheckout, for: .workspace)
        XCTAssertEqual(store.startScreenFolder(home: home), root.path, "no pane to follow, so the last pick")
    }

    @MainActor
    func testAPickOnTheScreenOutranksTheSettingForTheRestOfTheSession() throws {
        let store = StartingFolderStore(userDefaults: try makeDefaults())
        store.select(.home, for: .workspace)
        store.pickStartScreenFolder(root.path)
        XCTAssertEqual(store.startScreenFolder(home: home), root.path)
    }

    // MARK: - opening a workspace

    @MainActor
    func testTheWorkspaceOpensInTheFolderTheScreenShows() async {
        let client = RecordingClient()
        let viewModel = SessionViewModel(client: client)
        viewModel.update(model: model(workspaces: []), connection: .live)

        _ = await viewModel.startWorkspace(in: root.path)

        let created = await client.call("workspace.create")
        guard case .string(let cwd)? = created?["cwd"], case .bool(let focus)? = created?["focus"] else {
            return XCTFail("workspace.create carries a cwd and focus: \(String(describing: created))")
        }
        XCTAssertEqual(cwd, root.path)
        XCTAssertTrue(focus)
    }
}
