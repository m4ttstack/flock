import XCTest
@testable import FlockCore

private actor QuietClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}

@MainActor
final class SessionViewModelPinTests: XCTestCase {
    private func model(_ workspaces: [(id: String, label: String)]) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: workspaces.enumerated().map { index, item in
                WorkspaceRecord(
                    workspaceID: WorkspaceID(rawValue: item.id), label: item.label, number: index + 1,
                    activeTabID: TabID(rawValue: "\(item.id):t1"), agentStatus: .idle
                )
            },
            tabs: workspaces.map {
                TabRecord(tabID: TabID(rawValue: "\($0.id):t1"), workspaceID: WorkspaceID(rawValue: $0.id),
                          label: "zsh", number: 1, paneCount: 1, agentStatus: .idle)
            },
            panes: workspaces.map {
                PaneRecord(paneID: PaneID(rawValue: "\($0.id):p1"), workspaceID: WorkspaceID(rawValue: $0.id),
                           tabID: TabID(rawValue: "\($0.id):t1"), focused: false, agentStatus: .idle, revision: 0,
                           terminalTitleStripped: nil, label: nil, cwd: "/acme/\($0.label)", scroll: nil)
            },
            layouts: []
        ))
    }

    private func viewModel(notices: @escaping @MainActor (String) -> Void = { _ in }) -> (SessionViewModel, WorkspaceIdentityStore) {
        let identity = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: "flock-pin-vm-\(UUID().uuidString)")!)
        let viewModel = SessionViewModel(client: QuietClient(), noticeSink: notices, identity: identity)
        return (viewModel, identity)
    }

    func testPinningTakesTheNameTheFirstPaneFolderAndTheSymbol() {
        let (viewModel, identity) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        identity.assign(["w2"])
        let symbol = identity.symbol(for: "w2")
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        let pin = viewModel.pins.pins[0]
        XCTAssertEqual(pin.name, "web")
        XCTAssertEqual(pin.folder, "/acme/web")
        XCTAssertEqual(identity.symbol(for: pin.identityKey), symbol)
        XCTAssertEqual(viewModel.railSections(board: nil)?.workspaces.map(\.label), ["acme"])
    }

    func testUnpinningGivesTheSymbolBackToTheWorkspace() {
        let (viewModel, identity) = viewModel()
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        identity.setOverride("bird.fill", for: "w1")
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.unpin(viewModel.pins.pins[0].id)
        XCTAssertEqual(viewModel.pins.pins, [])
        XCTAssertEqual(identity.symbol(for: "w1"), "bird.fill")
    }

    func testAWorkspaceClosingLeavesAnEmptyPinThatOnlyRemoveDeletes() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([]), connection: .live)
        let pin = viewModel.pins.pins[0]
        XCTAssertNil(pin.workspace)
        viewModel.unpin(pin.id)
        XCTAssertEqual(viewModel.pins.pins.count, 1, "unpin needs a linked workspace")
        viewModel.removePin(pin.id)
        XCTAssertEqual(viewModel.pins.pins, [])
    }

    func testPinningASecondWorkspaceWithAPinnedNameIsRefusedWithANotice() {
        var notices: [String] = []
        let (viewModel, _) = viewModel(notices: { notices.append($0) })
        viewModel.update(model: model([("w1", "acme"), ("w2", "Acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(viewModel.pins.pins.count, 1)
        XCTAssertEqual(notices, ["A pinned workspace is already called \"Acme\"."])
    }

    func testRenamingAnEmptyPinIsLocalAndRefusesATakenName() {
        var notices: [String] = []
        let (viewModel, _) = viewModel(notices: { notices.append($0) })
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        viewModel.update(model: model([("w2", "web")]), connection: .live)
        let empty = viewModel.pins.pins[0]
        viewModel.renamePin(empty.id, to: "web")
        viewModel.renamePin(empty.id, to: "  ")
        viewModel.renamePin(empty.id, to: "acme api")
        XCTAssertEqual(viewModel.pins.pin(empty.id)?.name, "acme api")
        XCTAssertEqual(notices, ["A pinned workspace is already called \"web\"."])
    }
}
