import XCTest
@testable import FlockCore

private actor QuietClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}

/// A shell that has `cd`ed since herdr last pushed its folder.
/// A shell whose folder read waits for `release()`, so a test can act while
/// a new pin is still asking where it opens.
private actor HeldShellFolderClient: HerdrCommandClient {
    private var held: CheckedContinuation<Void, Never>?

    var isHeld: Bool { held != nil }

    func release() {
        held?.resume()
        held = nil
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.process_info" else { return Data("{}".utf8) }
        await withCheckedContinuation { held = $0 }
        return Data(#"{"result":{"process_info":{"foreground_process_group_id":7,"foreground_processes":[{"name":"zsh","pid":7,"cwd":"/acme/code/shell-now"}],"shell_pid":7}}}"#.utf8)
    }
}

private struct ShellFolderClient: HerdrCommandClient {
    let folder: String

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.process_info" else { return Data("{}".utf8) }
        return Data(#"{"result":{"process_info":{"foreground_process_group_id":7,"foreground_processes":[{"name":"zsh","pid":7,"cwd":"\#(folder)"}],"shell_pid":7}}}"#.utf8)
    }
}

/// Answers `workspace.create` with a new workspace w3 and records every ask.
private actor CreatingClient: HerdrCommandClient {
    private(set) var asks: [(method: String, params: [String: JSONValue])] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        asks.append((method, params))
        guard method == "workspace.create" else { return Data("{}".utf8) }
        return Data(#"{"result":{"tab":{"tab_id":"w3:t1","workspace_id":"w3"},"root_pane":{"pane_id":"w3:p1"}}}"#.utf8)
    }
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
    private func model(_ workspaces: [(id: String, label: String)], focused: String? = nil) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: focused.map { WorkspaceID(rawValue: $0) },
            focusedTabID: focused.map { TabID(rawValue: "\($0):t1") },
            focusedPaneID: focused.map { PaneID(rawValue: "\($0):p1") },
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

    private func viewModel(
        client: any HerdrCommandClient = QuietClient(), executor: (any PlanExecuting)? = nil,
        notices: @escaping @MainActor (String) -> Void = { _ in }
    ) -> (SessionViewModel, WorkspaceIdentityStore) {
        let suite = "flock-pin-vm-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: suite)!)
        let viewModel = SessionViewModel(
            client: client, planExecutor: executor, noticeSink: notices, identity: identity, folderExists: { _ in true }
        )
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

    func testPinningAsksWhereThePinOpensAndCancellingKeepsTheFirstPanesFolder() async throws {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        let first = viewModel.pins.pins[0]
        try await waitForAsk(first.id, on: viewModel)
        XCTAssertEqual(
            viewModel.pinFolderAsk?.choices, [PinFolderAsk.Choice(folder: "/acme/acme", reason: .shellLastSeen)],
            "a shell herdr cannot place offers where it was last seen, once"
        )
        viewModel.answerPinFolder(first.id, with: nil)
        XCTAssertNil(viewModel.pinAwaitingFolder)
        XCTAssertEqual(viewModel.pins.pin(first.id)?.folder, "/acme/acme")
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        let second = viewModel.pins.pins[1]
        try await waitForAsk(second.id, on: viewModel)
        viewModel.answerPinFolder(second.id, with: "/acme/code/web")
        XCTAssertEqual(viewModel.pins.pin(second.id)?.folder, "/acme/code/web")
        XCTAssertNil(viewModel.pinAwaitingFolder)
    }

    /// herdr pushes no event for a `cd`, so the model still holds the folder
    /// the shell started in; the ask starts where the shell is now.
    func testPinningAsksFromWhereTheShellIsNowNotWhereItStarted() async throws {
        let (viewModel, _) = viewModel(client: ShellFolderClient(folder: "/acme/code/training-plan"))
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        let pin = viewModel.pins.pins[0]
        try await waitForAsk(pin.id, on: viewModel)
        XCTAssertEqual(viewModel.pins.pin(pin.id)?.folder, "/acme/code/training-plan")
        XCTAssertEqual(viewModel.pinFolderAsk?.choices, [
            PinFolderAsk.Choice(folder: "/acme/code/training-plan", reason: .shellNow),
            PinFolderAsk.Choice(folder: "/acme/acme", reason: .shellStarted),
        ])
    }

    private struct NeverAsked: Error {}

    private func waitForAsk(_ id: PinID, on viewModel: SessionViewModel) async throws {
        for _ in 0..<200 where viewModel.pinAwaitingFolder != id {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard viewModel.pinAwaitingFolder == id else {
            XCTFail("the folder was never asked for")
            throw NeverAsked()
        }
    }

    // MARK: - an empty pin shown in place of a workspace

    func testClosingTheShownPinnedWorkspaceKeepsItsEmptyPinOnScreen() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w1"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        XCTAssertEqual(viewModel.shownEmptyPin, viewModel.pins.pins[0].id)
        XCTAssertNil(viewModel.shownWorkspaceID, "no workspace is shown beside it")
        XCTAssertNil(viewModel.canvasFocusedPaneID, "no pane takes the keyboard")
    }

    func testClosingAnUnpinnedOrUnshownWorkspaceMovesOnAsBefore() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w1"), connection: .live)
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        XCTAssertNil(viewModel.shownEmptyPin)
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w2"))

        viewModel.update(model: model([("w2", "web"), ("w3", "docs")], focused: "w2"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w3"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        XCTAssertNil(viewModel.shownEmptyPin, "a pinned workspace closing behind the shown one moves nothing")
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w2"))
    }

    func testShowingAnEmptyPinRunsNothingAndPickingAWorkspaceLeavesIt() async {
        let client = CreatingClient()
        let (viewModel, _) = viewModel(client: client)
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w2"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        let pin = viewModel.pins.pins[0].id
        viewModel.show(emptyPin: pin)
        XCTAssertEqual(viewModel.shownEmptyPin, pin)
        let asks = await client.asks
        XCTAssertTrue(asks.isEmpty, "showing a pin asks herdr for nothing")
        viewModel.select(workspace: WorkspaceID(rawValue: "w2"))
        XCTAssertNil(viewModel.shownEmptyPin)
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w2"))
    }

    func testAFolderChosenWhileTheShellIsReadWinsAndIsNotAskedAgain() async throws {
        let client = HeldShellFolderClient()
        let (viewModel, _) = viewModel(client: client)
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        let pin = viewModel.pins.pins[0]
        for _ in 0..<500 where !(await client.isHeld) {
            try await Task.sleep(for: .milliseconds(2))
        }
        viewModel.setPinFolder(pin.id, to: "/acme/code/chosen")
        await client.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(viewModel.pins.pin(pin.id)?.folder, "/acme/code/chosen")
        XCTAssertNil(viewModel.pinFolderAsk)
    }

    func testMovingTheShownPinnedWorkspaceToTheTopBarLeavesNoEmptyPin() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w1"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.moveToTopBar(pin: viewModel.pins.pins[0].id, at: nil)
        XCTAssertNil(viewModel.shownEmptyPin, "it is open in the top bar, not closed")
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w2"))
    }

    func testATopBarPinIsNeverShownEmpty() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w2"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        let pin = viewModel.pins.pins[0].id
        viewModel.moveToTopBar(pin: pin, at: nil)
        viewModel.show(emptyPin: pin)
        XCTAssertNil(viewModel.shownEmptyPin)
    }

    func testAnOpenPinIsNeverShownEmpty() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme")], focused: "w1"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.show(emptyPin: viewModel.pins.pins[0].id)
        XCTAssertNil(viewModel.shownEmptyPin)
    }

    func testStartingTheShownPinOpensItInItsFolderAndShowsTheNewWorkspace() async {
        let client = CreatingClient()
        let (viewModel, _) = viewModel(client: client)
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w1"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        let pin = viewModel.pins.pins[0].id
        let pane = await viewModel.start(emptyPin: pin)
        XCTAssertEqual(pane, PaneID(rawValue: "w3:p1"))
        XCTAssertNil(viewModel.shownEmptyPin)
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w3"))
        let create = await client.asks.first { $0.method == "workspace.create" }
        guard case let .string(cwd) = create?.params["cwd"] else { return XCTFail("the create named no folder") }
        XCTAssertEqual(cwd, "/acme/acme")
    }

    func testRemovingTheShownPinShowsTheWorkspaceBehindIt() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w1"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        viewModel.removePin(viewModel.pins.pins[0].id)
        XCTAssertNil(viewModel.shownEmptyPin)
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w2"))
    }

    func testAShownPinThatHerdrReopensShowsItsWorkspace() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")], focused: "w1"), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([("w2", "web")], focused: "w2"), connection: .live)
        viewModel.update(model: model([("w2", "web"), ("w3", "acme")], focused: "w2"), connection: .live)
        XCTAssertNil(viewModel.shownEmptyPin)
        XCTAssertEqual(viewModel.shownWorkspaceID, WorkspaceID(rawValue: "w3"))
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
