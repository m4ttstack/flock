import XCTest
@testable import FlockCore

private actor CreatingClient: HerdrCommandClient {
    private(set) var calls: [(String, [String: JSONValue])] = []
    /// Runs while `workspace.create` is in flight, before it answers.
    private let whileCreating: (@MainActor @Sendable () -> Void)?

    init(whileCreating: (@MainActor @Sendable () -> Void)? = nil) {
        self.whileCreating = whileCreating
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        guard method == "workspace.create" else { return Data("{}".utf8) }
        await whileCreating?()
        return Data(#"{"result":{"type":"tab_created","tab":{"tab_id":"wN:t1","workspace_id":"wN"},"root_pane":{"pane_id":"wN:p1"}}}"#.utf8)
    }
}

private actor FailingClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        throw HerdrClientError.transport("socket closed")
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
private final class Box<Value> {
    var value: Value?
}

@MainActor
private final class FakePaneAgentStatusSubscriber: PaneAgentStatusSubscribing {
    private(set) var armed: Set<PaneID> = []

    func subscribe(pane: PaneID) { armed.insert(pane) }
    func unsubscribe(pane: PaneID) { armed.remove(pane) }
}

@MainActor
final class SessionViewModelTopBarTests: XCTestCase {
    /// `tabs` per workspace id; one when absent. `statuses` per workspace id
    /// for its first pane; idle when absent.
    private func model(
        _ workspaces: [(id: String, label: String)], tabs: [String: Int] = [:], focused: String? = nil,
        statuses: [String: AgentStatus] = [:]
    ) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: focused.map { WorkspaceID(rawValue: $0) },
            focusedTabID: focused.map { TabID(rawValue: "\($0):t1") }, focusedPaneID: nil,
            workspaces: workspaces.enumerated().map { index, item in
                WorkspaceRecord(workspaceID: WorkspaceID(rawValue: item.id), label: item.label, number: index + 1,
                                activeTabID: TabID(rawValue: "\(item.id):t1"), agentStatus: .idle)
            },
            tabs: workspaces.flatMap { item in
                (1...(tabs[item.id] ?? 1)).map { n in
                    TabRecord(tabID: TabID(rawValue: "\(item.id):t\(n)"), workspaceID: WorkspaceID(rawValue: item.id),
                              label: "zsh", number: n, paneCount: 1, agentStatus: .idle)
                }
            },
            panes: workspaces.map {
                PaneRecord(paneID: PaneID(rawValue: "\($0.id):p1"), workspaceID: WorkspaceID(rawValue: $0.id),
                           tabID: TabID(rawValue: "\($0.id):t1"), focused: false, agentStatus: statuses[$0.id] ?? .idle,
                           revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/acme/\($0.label)", scroll: nil)
            },
            layouts: []
        ))
    }

    private func viewModel(
        client: any HerdrCommandClient = CreatingClient(),
        executor: (any PlanExecuting)? = nil,
        subscriber: (any PaneAgentStatusSubscribing)? = nil,
        notices: @escaping @MainActor (String) -> Void = { _ in }
    ) -> SessionViewModel {
        let suite = "flock-topbar-vm-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: suite)!)
        return SessionViewModel(client: client, planExecutor: executor, paneAgentStatusSubscriber: subscriber,
                                noticeSink: notices, identity: identity)
    }

    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")

    func testMovingAOneTabWorkspaceHidesItEverywhereButKeepsItLinked() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertEqual(vm.model?.workspaces.map(\.workspaceID), [w1])
        XCTAssertEqual(vm.userModel?.workspaces.map(\.workspaceID), [w1, w2])
        let pin = vm.pins.pins(in: .topBar)[0]
        XCTAssertEqual(pin.workspace, w2)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        XCTAssertEqual(vm.pins.pin(pin.id)?.workspace, w2, "a reconcile must not empty a top-bar pin")
        XCTAssertTrue(vm.isOpen(pin))
        XCTAssertEqual(vm.railSections(board: nil)?.topBar.first?.record?.workspaceID, w2)
    }

    func testAWorkspaceWithTwoTabsIsRefusedWithAnAlert() {
        var notices: [String] = []
        let vm = viewModel(notices: { notices.append($0) })
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], tabs: ["w2": 2]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertTrue(vm.pins.pins.isEmpty)
        XCTAssertEqual(vm.topBarRefusal, TopBarRefusal(name: "dash", tabs: 2))
        XCTAssertTrue(vm.topBarRefusal?.message.contains("one tab") ?? false)
        XCTAssertEqual(notices, [], "the refusal is an alert, not a notice")
        vm.dismissTopBarRefusal()
        XCTAssertNil(vm.topBarRefusal)
    }

    func testARailPinWithTwoTabsIsRefusedAndStaysInTheRail() {
        var notices: [String] = []
        let vm = viewModel(notices: { notices.append($0) })
        vm.update(model: model([("w2", "dash")], tabs: ["w2": 3]), connection: .live)
        vm.pin(workspace: w2)
        let pin = vm.pins.pins[0]
        vm.moveToTopBar(pin: pin.id, at: nil)
        XCTAssertEqual(vm.pins.pin(pin.id)?.placement, .rail)
        XCTAssertEqual(vm.topBarRefusal, TopBarRefusal(name: "dash", tabs: 3))
        XCTAssertEqual(notices, [])
    }

    func testAnEmptyPinMayMoveToTheTopBar() {
        let vm = viewModel()
        vm.update(model: model([("w2", "dash")]), connection: .live)
        vm.pin(workspace: w2)
        vm.update(model: model([]), connection: .live)
        let pin = vm.pins.pins[0]
        vm.moveToTopBar(pin: pin.id, at: nil)
        XCTAssertEqual(vm.pins.pin(pin.id)?.placement, .topBar)
    }

    func testMovingTheSelectedWorkspaceLandsTheSelectionOnANeighbour() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w2"), connection: .live)
        XCTAssertEqual(vm.selectedWorkspaceID, w2)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertEqual(vm.selectedWorkspaceID, w1)
    }

    func testMovingBackToTheSidebarShowsItAgain() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.moveToSidebar(pin: vm.pins.pins[0].id, at: 0)
        XCTAssertEqual(vm.model?.workspaces.map(\.workspaceID), [w1, w2])
        XCTAssertEqual(vm.railSections(board: nil)?.pinned.map(\.pin.name), ["dash"])
    }

    func testOpeningAnEmptyTopBarPinCreatesWithoutFocusOrSelection() async {
        let client = CreatingClient()
        let vm = viewModel(client: client)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w1"), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: model([("w1", "acme")], focused: "w1"), connection: .live)
        let pin = vm.pins.pins(in: .topBar)[0]
        XCTAssertNil(pin.workspace)
        await vm.toggleTopBar(pin.id)
        XCTAssertEqual(vm.topBarOverlay.openPin, pin.id)
        XCTAssertEqual(vm.selectedWorkspaceID, w1)
        let create = await client.calls.first { $0.0 == "workspace.create" }
        guard case .bool(let focus)? = create?.1["focus"] else { return XCTFail("workspace.create sent no focus") }
        XCTAssertFalse(focus)
        XCTAssertEqual(vm.pins.pin(pin.id)?.workspace, WorkspaceID(rawValue: "wN"))
    }

    func testTheOverlayStaysOnTheLoaderThroughAnUpdateWhileTheCreateIsOut() async {
        let holder = Box<SessionViewModel>()
        let seen = Box<PinID>()
        let during = model([("w1", "acme")], focused: "w1")
        let client = CreatingClient {
            holder.value?.update(model: during, connection: .live)
            seen.value = holder.value?.topBarOverlay.openPin
        }
        let vm = viewModel(client: client)
        holder.value = vm
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w1"), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: during, connection: .live)
        let pin = vm.pins.pins(in: .topBar)[0]
        await vm.toggleTopBar(pin.id)
        XCTAssertEqual(seen.value, pin.id)
        XCTAssertEqual(vm.topBarOverlay.openPin, pin.id)
    }

    func testRenamingAnOpenTopBarPinRenamesTheWorkspaceInHerdr() async {
        let executor = RecordingExecutor()
        let vm = viewModel(executor: executor)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        await vm.renameTopBarPin(vm.pins.pins[0].id, to: " board ")
        XCTAssertEqual(executor.plans.flatMap(\.ops), [.renameWorkspace(w2, "board")])
    }

    func testRenamingAnEmptyTopBarPinRenamesThePin() async {
        let executor = RecordingExecutor()
        let vm = viewModel(executor: executor)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: model([("w1", "acme")]), connection: .live)
        await vm.renameTopBarPin(vm.pins.pins[0].id, to: "board")
        XCTAssertEqual(vm.pins.pins[0].name, "board")
        XCTAssertTrue(executor.plans.isEmpty)
    }

    func testAFailedCreateClosesTheOverlay() async {
        let vm = viewModel(client: FailingClient())
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: model([("w1", "acme")]), connection: .live)
        let pin = vm.pins.pins(in: .topBar)[0]
        await vm.toggleTopBar(pin.id)
        XCTAssertNil(vm.topBarOverlay.openPin)
    }

    /// The overlay's panes take the keyboard, so no canvas under it may claim
    /// it back, the main one or a solo one.
    func testEveryCanvasYieldsTheKeyboardWhileTheOverlayIsOpen() async {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w1"), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        let shown = PaneID(rawValue: "w1:p1")
        XCTAssertEqual(vm.canvasFocus(solo: shown), shown)
        let pin = vm.pins.pins(in: .topBar)[0]
        await vm.toggleTopBar(pin.id)
        XCTAssertNil(vm.canvasFocus(solo: nil))
        XCTAssertNil(vm.canvasFocus(solo: shown))
        await vm.toggleTopBar(pin.id)
        XCTAssertEqual(vm.canvasFocus(solo: shown), shown)
    }

    func testTheMainViewsCommandsStandDownUnderTheOverlayOrTheRtModal() async {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w1"), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertFalse(vm.modalIsUp)
        let pin = vm.pins.pins(in: .topBar)[0]
        await vm.toggleTopBar(pin.id)
        XCTAssertTrue(vm.modalIsUp)
        await vm.toggleTopBar(pin.id)
        XCTAssertFalse(vm.modalIsUp)
        vm.rt.modal = RtModal(itemID: "tok1", tabID: TabID(rawValue: "w1:t1"), serviceTabID: nil)
        XCTAssertTrue(vm.modalIsUp)
    }

    /// herdr's workspace-created event may land before the create's reply.
    func testAWorkspaceCreatedForAnEmptyPinNeverShowsInTheRail() async {
        let holder = Box<SessionViewModel>()
        let created = model([("w1", "acme"), ("wN", "shell")], focused: "w1")
        let client = CreatingClient { holder.value?.update(model: created, connection: .live) }
        let vm = viewModel(client: client)
        holder.value = vm
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w1"), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: model([("w1", "acme")], focused: "w1"), connection: .live)
        await vm.toggleTopBar(vm.pins.pins(in: .topBar)[0].id)
        XCTAssertEqual(vm.model?.workspaces.map(\.workspaceID), [w1])
        XCTAssertEqual(vm.railSections(board: nil)?.workspaces.map(\.workspaceID), [w1])
    }

    func testTogglingTheOpenPinClosesAndAnEmptiedPinClosesTheOverlay() async {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        let pin = vm.pins.pins(in: .topBar)[0]
        await vm.toggleTopBar(pin.id)
        XCTAssertEqual(vm.topBarOverlay.openPin, pin.id)
        await vm.toggleTopBar(pin.id)
        XCTAssertNil(vm.topBarOverlay.openPin)
        await vm.toggleTopBar(pin.id)
        vm.update(model: model([("w1", "acme")]), connection: .live)
        XCTAssertNil(vm.topBarOverlay.openPin)
    }

    func testUnpinningAnOpenTopBarPinPutsTheWorkspaceBackInTheRail() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.unpinTopBar(vm.pins.pins[0].id)
        XCTAssertTrue(vm.pins.pins.isEmpty)
        XCTAssertEqual(vm.railSections(board: nil)?.workspaces.map(\.workspaceID), [w1, w2])
    }

    func testATopBarWorkspaceRaisesNoToastWhileThereOrOnTheWayBack() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], statuses: ["w2": .working]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], statuses: ["w2": .blocked]), connection: .live)
        XCTAssertTrue(vm.attentionToasts.toasts.isEmpty)
        vm.moveToSidebar(pin: vm.pins.pins[0].id, at: nil)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], statuses: ["w2": .blocked]), connection: .live)
        XCTAssertTrue(vm.attentionToasts.toasts.isEmpty)
    }

    func testATopBarWorkspaceKeepsItsAgentStatusFeed() {
        let subscriber = FakePaneAgentStatusSubscriber()
        let vm = viewModel(subscriber: subscriber)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertEqual(subscriber.armed, [PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w2:p1")])
    }

    func testTopBarStatusIsNilWhileEmptyAndTheWorkspaceStatusWhileOpen() {
        let vm = viewModel()
        vm.update(model: model([("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        let pin = vm.pins.pins(in: .topBar)[0]
        XCTAssertEqual(vm.topBarStatus(of: pin), ShownStatus(AgentStatus.idle))
        vm.update(model: model([]), connection: .live)
        XCTAssertNil(vm.topBarStatus(of: vm.pins.pins(in: .topBar)[0]))
    }
    func testDragsMovePinsBetweenTheBarAndPinnedAndRefuseTwoTabs() async {
        var notices: [String] = []
        let vm = viewModel(notices: { notices.append($0) })
        vm.update(model: model([("w1", "acme"), ("w2", "dash"), ("w3", "logs")], tabs: ["w3": 2]), connection: .live)
        vm.pin(workspace: w1)
        vm.pin(workspace: w2)
        vm.pin(workspace: WorkspaceID(rawValue: "w3"))
        let ids = vm.pins.pins.map(\.id)
        let up = await vm.perform(subject: .pin(ids[1]), target: .topBar(insertIndex: 0))
        XCTAssertEqual(up, .committed)
        XCTAssertEqual(vm.pins.pins(in: .topBar).map(\.name), ["dash"])
        let refused = await vm.perform(subject: .pin(ids[2]), target: .topBar(insertIndex: 1))
        XCTAssertEqual(refused, .noOp)
        XCTAssertEqual(vm.topBarRefusal, TopBarRefusal(name: "logs", tabs: 2))
        XCTAssertEqual(notices, [])
        let down = await vm.perform(subject: .pin(ids[1]), target: .pinnedRail(insertIndex: 0))
        XCTAssertEqual(down, .committed)
        XCTAssertEqual(vm.pins.pins(in: .rail).map(\.name), ["dash", "acme", "logs"])
    }

    func testDraggingACellAlongTheBarReordersItWithoutTheTabCheck() async {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w1, at: nil)
        vm.moveToTopBar(workspace: w2, at: nil)
        let bar = vm.pins.pins(in: .topBar).map(\.id)
        let moved = await vm.perform(subject: .pin(bar[1]), target: .topBar(insertIndex: 0))
        XCTAssertEqual(moved, .committed)
        XCTAssertEqual(vm.pins.pins(in: .topBar).map(\.name), ["dash", "acme"])
        let same = await vm.perform(subject: .pin(bar[1]), target: .topBar(insertIndex: 1))
        XCTAssertEqual(same, .noOp, "a cell dropped back in its own gap changes nothing")
    }

    func testACellDroppedAnywhereButTheBarOrPinnedCancels() async {
        let executor = RecordingExecutor()
        let vm = viewModel(executor: executor)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        let pin = vm.pins.pins(in: .topBar)[0]
        let targets: [DropTarget] = [
            .workspaceRail(insertIndex: 0), .workspaceRail(insertIndex: 1), .workspaceThumbnail(w1),
            .tabThumbnail(TabID(rawValue: "w1:t1")), .tabStrip(workspace: w1, insertIndex: 0), .newTab(w1),
            .newWorkspace, .paneInterior(PaneID(rawValue: "w1:p1")), .paneEdge(PaneID(rawValue: "w1:p1"), .left),
        ]
        for target in targets {
            let outcome = await vm.perform(subject: .pin(pin.id), target: target)
            XCTAssertEqual(outcome, .noOp, "\(target)")
            XCTAssertEqual(vm.pins.pin(pin.id)?.placement, .topBar, "\(target)")
            XCTAssertEqual(vm.pins.pins.count, 1, "\(target)")
        }
        XCTAssertTrue(executor.plans.isEmpty)
    }
}
