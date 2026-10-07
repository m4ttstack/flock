import XCTest
@testable import FlockCore

private actor QuietClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}

@MainActor
private final class RecordingExecutor: PlanExecuting {
    private(set) var plans: [OpPlan] = []

    func execute(_ plan: OpPlan) async -> Result<ExecutedPlan, OpFailure> {
        plans.append(plan)
        return .success(ExecutedPlan(plan: plan, inverse: OpPlan(ops: [], label: "Undo")))
    }
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

    private func viewModel(executor: (any PlanExecuting)? = nil, notices: @escaping @MainActor (String) -> Void = { _ in }) -> (SessionViewModel, WorkspaceIdentityStore) {
        let identity = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: "flock-pin-vm-\(UUID().uuidString)")!)
        let viewModel = SessionViewModel(client: QuietClient(), planExecutor: executor, noticeSink: notices, identity: identity)
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

    func testClosingAPinnedWorkspacesLastTabAsksNothing() async {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        await viewModel.closeTab(TabID(rawValue: "w1:t1"))
        XCTAssertNotNil(viewModel.pendingClose, "an ordinary workspace still asks")
        viewModel.cancelPendingClose()
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        await viewModel.closeTab(TabID(rawValue: "w1:t1"))
        XCTAssertNil(viewModel.pendingClose)
    }

    func testRenamingAPinnedWorkspaceToAnotherPinsNameIsRefused() async {
        var notices: [String] = []
        let (viewModel, _) = viewModel(notices: { notices.append($0) })
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        await viewModel.commitRename("ACME", for: .workspace(WorkspaceID(rawValue: "w2")))
        XCTAssertEqual(notices, ["A pinned workspace is already called \"ACME\"."])
    }

    func testDroppingAWorkspaceOnPinnedPinsItAndAPinOnWorkspacesUnpinsIt() async {
        let (viewModel, _) = viewModel(executor: RecordingExecutor())
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        _ = await viewModel.perform(subject: .workspace(WorkspaceID(rawValue: "w2")), target: .pinnedRail(insertIndex: 0))
        XCTAssertEqual(viewModel.pins.pins.map(\.name), ["web"])
        _ = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 0))
        XCTAssertEqual(viewModel.pins.pins, [])
    }

    func testDroppingAPinWithinPinnedReorders() async {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        _ = await viewModel.perform(subject: .pin(viewModel.pins.pins[1].id), target: .pinnedRail(insertIndex: 0))
        XCTAssertEqual(viewModel.pins.pins.map(\.name), ["web", "acme"])
    }

    func testAnEmptyPinCannotLeavePinned() async {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([]), connection: .live)
        let outcome = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 0))
        XCTAssertEqual(outcome, .noOp)
        XCTAssertEqual(viewModel.pins.pins.count, 1)
    }

    func testAPinDroppedAmongWorkspacesIsPlannedAgainstTheRailThatWasDrawn() async {
        let executor = RecordingExecutor()
        let (viewModel, _) = viewModel(executor: executor)
        viewModel.update(model: model([("a", "a"), ("w", "w"), ("b", "b"), ("c", "c")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w"))
        let outcome = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 2))
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(executor.plans.first?.ops, [.moveWorkspace(WorkspaceID(rawValue: "w"), insertIndex: 3)])
        XCTAssertEqual(viewModel.pins.pins, [])
    }

    func testAPinStaysWhenItsMoveInHerdrIsNotAttempted() async {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("a", "a"), ("w", "w")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w"))
        let outcome = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 0))
        XCTAssertEqual(outcome, .notAttempted)
        XCTAssertEqual(viewModel.pins.pins.count, 1)
    }

    func testABlockDropAdvancesOnlyOverPinsThatLanded() async {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("a", "a"), ("b", "b"), ("c", "c")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "b"))
        let ids = ["a", "b", "c"].map(WorkspaceID.init(rawValue:))
        let outcome = await viewModel.perform(subject: .workspaces(ids), target: .pinnedRail(insertIndex: 0))
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(viewModel.pins.pins.map(\.name), ["a", "b", "c"])
    }

    func testAPinDropThatChangesNothingIsANoOp() async {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("a", "a")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "a"))
        let outcome = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .pinnedRail(insertIndex: 0))
        XCTAssertEqual(outcome, .noOp)
    }

    func testAPinDroppedWhereItsWorkspaceAlreadySitsUnpinsWithoutAMove() async {
        let executor = RecordingExecutor()
        let (viewModel, _) = viewModel(executor: executor)
        viewModel.update(model: model([("a", "a"), ("w", "w"), ("b", "b"), ("c", "c")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w"))
        let outcome = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 1))
        XCTAssertEqual(outcome, .committed)
        XCTAssertTrue(executor.plans.isEmpty)
        XCTAssertEqual(viewModel.pins.pins, [])
    }
}
