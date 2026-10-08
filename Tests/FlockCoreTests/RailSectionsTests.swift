import XCTest
@testable import FlockCore

private func model(_ labels: [String]) -> SessionModel {
    let workspaces = labels.enumerated().map { index, label in
        WorkspaceRecord(
            workspaceID: WorkspaceID(rawValue: "w\(index + 1)"), label: label, number: index + 1,
            activeTabID: TabID(rawValue: "w\(index + 1):t1"), agentStatus: .idle
        )
    }
    return SessionModel(snapshot: SessionSnapshot(
        version: "0.9.0", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
        workspaces: workspaces, tabs: [], panes: [], layouts: []
    ))
}

private func workspace(_ id: String, _ status: AgentStatus) -> WorkspaceRecord {
    WorkspaceRecord(
        workspaceID: WorkspaceID(rawValue: id), label: id, number: 1, activeTabID: TabID(rawValue: "\(id):t1"), agentStatus: status
    )
}

private let board = BoardWorkspaceNames(reviews: "🛹 Reviews", responds: "🛹 Responses", doctors: "🛹 Doctors")

final class RailSectionsTests: XCTestCase {
    // MARK: - Pins

    func testLinkedPinsLeaveWorkspacesAndLeadTheRailOrder() {
        let model = model(["acme", "notes", "web"])
        let pins = [
            PinnedWorkspace(id: PinID(rawValue: "p1"), name: "web", folder: "/web", workspace: WorkspaceID(rawValue: "w3"), syncedLabel: "web", confirmed: true),
            PinnedWorkspace(id: PinID(rawValue: "p2"), name: "gone", folder: "/gone", workspace: nil, syncedLabel: nil, confirmed: false),
        ]
        let sections = RailSections(model: model, board: nil, pins: pins)
        XCTAssertEqual(sections.workspaces.map(\.label), ["acme", "notes"])
        XCTAssertEqual(sections.pinned.map(\.pin.name), ["web", "gone"])
        XCTAssertEqual(sections.pinned.map { $0.record?.label }, ["web", nil])
        XCTAssertEqual(sections.railOrder.map(\.rawValue), ["w3", "w1", "w2"])
        XCTAssertEqual(sections.navigationOrder { _ in false }.map(\.title), ["web", "acme", "notes"])
    }

    /// Pins are made from the workspace menu, which a herd has none of, but
    /// one adopted by name or restored by id still shows in PINNED alone.
    func testALinkedPinLeavesHerdsAndBoardToo() {
        let model = model(["herd: acme-batch", "🛹 Reviews", "acme"])
        let pins = [
            PinnedWorkspace(id: PinID(rawValue: "p1"), name: "herd: acme-batch", folder: "/acme", workspace: WorkspaceID(rawValue: "w1"), syncedLabel: nil, confirmed: true),
            PinnedWorkspace(id: PinID(rawValue: "p2"), name: "🛹 Reviews", folder: "/acme", workspace: WorkspaceID(rawValue: "w2"), syncedLabel: nil, confirmed: true),
        ]
        let sections = RailSections(model: model, board: board, pins: pins)
        XCTAssertEqual(sections.herds, [])
        XCTAssertNil(sections.herdSummary, "no herds left, so no section")
        XCTAssertEqual(sections.board, [])
        XCTAssertEqual(sections.workspaces.map(\.label), ["acme"])
        XCTAssertEqual(sections.railOrder.map(\.rawValue), ["w1", "w2", "w3"])
    }

    func testModelInsertIndexSkipsPinnedWorkspaces() {
        let model = model(["acme", "web", "notes"])
        let pinned: Set<WorkspaceID> = [WorkspaceID(rawValue: "w2")]
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 1, in: model, board: nil, pinned: pinned), 2)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: model, board: nil, pinned: pinned), 3)
    }

    // MARK: - The split

    func testReviewsAndHerdsAreNamedByTheirSections() {
        let sections = RailSections(model: model(["flock", "🛹 Reviews", "herd: acme-batch"]), board: board)
        XCTAssertEqual(sections.reviewIDs, [WorkspaceID(rawValue: "w2")])
        XCTAssertEqual(sections.herdIDs, [WorkspaceID(rawValue: "w3")])
    }

    func testBoardsWorkspacesLeaveTheRegularListForTheirOwnSection() {
        let sections = RailSections(model: model(["flock", "🛹 Reviews", "repo-tools", "🛹 Doctors"]), board: board)
        XCTAssertEqual(sections.workspaces.map(\.label), ["flock", "repo-tools"])
        XCTAssertEqual(sections.board.map(\.label), ["🛹 Reviews", "🛹 Doctors"])
    }

    /// Board lists by role, whatever order herdr holds them in, and only the
    /// ones that exist.
    func testBoardIsInRoleOrderAndListsOnlyWhatExists() {
        let sections = RailSections(model: model(["🛹 Doctors", "flock", "🛹 Responses", "🛹 Reviews"]), board: board)
        XCTAssertEqual(sections.board.map(\.label), ["🛹 Reviews", "🛹 Responses", "🛹 Doctors"])

        let partial = RailSections(model: model(["🛹 Doctors", "flock"]), board: board)
        XCTAssertEqual(partial.board.map(\.label), ["🛹 Doctors"])
    }

    func testTheMatchIsExact() {
        let sections = RailSections(model: model(["🛹 reviews", "Reviews", "🛹 Reviews (old)"]), board: board)
        XCTAssertTrue(sections.board.isEmpty)
        XCTAssertEqual(sections.workspaces.count, 3)
    }

    /// Board targets by label alone, so every workspace carrying a name is
    /// its: two of them both land in the section, in herdr's order.
    func testTwoWorkspacesWithOneRolesLabelAreBothBoards() {
        let sections = RailSections(model: model(["🛹 Doctors", "🛹 Reviews", "🛹 Doctors"]), board: board)
        XCTAssertEqual(sections.board.map(\.workspaceID.rawValue), ["w2", "w1", "w3"])
    }

    func testTwoRolesSharingAWorkspaceListItOnce() {
        let shared = BoardWorkspaceNames(reviews: "board", responds: "board", doctors: "doctors")
        let sections = RailSections(model: model(["board", "doctors"]), board: shared)
        XCTAssertEqual(sections.board.map(\.workspaceID.rawValue), ["w1", "w2"])
    }

    func testNoBoardConfigMeansNoBoardSection() {
        let sections = RailSections(model: model(["flock", "reviews", "doctors"]), board: nil)
        XCTAssertTrue(sections.board.isEmpty)
        XCTAssertEqual(sections.workspaces.map(\.label), ["flock", "reviews", "doctors"])
    }

    func testAConfigWhoseWorkspacesDoNotExistMeansNoBoardSection() {
        let sections = RailSections(model: model(["flock", "repo-tools"]), board: board)
        XCTAssertTrue(sections.board.isEmpty)
    }

    /// Herds keep their own section, and a label that somehow names both a
    /// herd and a board role is the herd's.
    func testAHerdIsAHerdEvenWhenBoardNamesIt() {
        let collision = BoardWorkspaceNames(reviews: "herd: review-shapes", responds: "responses", doctors: "doctors")
        let sections = RailSections(model: model(["flock", "herd: review-shapes", "responses"]), board: collision)
        XCTAssertEqual(sections.herds.map(\.workspaceID.rawValue), ["w2"])
        XCTAssertEqual(sections.board.map(\.workspaceID.rawValue), ["w3"])
        XCTAssertEqual(sections.workspaces.map(\.workspaceID.rawValue), ["w1"])
        XCTAssertNotNil(sections.herdSummary)
        XCTAssertFalse(RailSections.isRailRow(label: "herd: review-shapes", board: collision))
    }

    func testEveryWorkspaceLandsInExactlyOneSection() {
        let labels = ["flock", "herd: ci-sweep", "🛹 Reviews", "repo-tools", "🛹 Doctors", "herd: acme-batch"]
        let sections = RailSections(model: model(labels), board: board)
        let listed = sections.workspaces.map(\.workspaceID) + sections.board.map(\.workspaceID) + sections.herds.map(\.workspaceID)
        XCTAssertEqual(Set(listed).count, labels.count)
        XCTAssertEqual(listed.count, labels.count)
    }

    // MARK: - The folded header's dot

    func testAFoldedHeaderShowsTheLoudestBoardStatus() {
        let rows = [workspace("r", .working), workspace("s", .blocked), workspace("d", .done)]
        XCTAssertEqual(RailSections.boardHeaderStatus(for: rows, isCollapsed: true), .blocked)
        XCTAssertEqual(
            RailSections.boardHeaderStatus(for: [workspace("r", .working), workspace("d", .done)], isCollapsed: true), .done,
            "herdr ranks done above working"
        )
        XCTAssertEqual(RailSections.boardHeaderStatus(for: [workspace("r", .idle), workspace("d", .working)], isCollapsed: true), .working)
    }

    /// Idle and unknown are resting states, which a folded header has no
    /// reason to raise.
    func testNothingActiveMeansNoDot() {
        XCTAssertNil(RailSections.boardHeaderStatus(for: [workspace("r", .idle), workspace("d", .unknown)], isCollapsed: true))
        XCTAssertNil(RailSections.boardHeaderStatus(for: [], isCollapsed: true))
    }

    func testAnOpenSectionsHeaderShowsNoDot() {
        XCTAssertNil(RailSections.boardHeaderStatus(for: [workspace("s", .blocked)], isCollapsed: false))
    }

    // MARK: - Reorder index

    /// The rail drags regular workspaces among themselves, and herdr moves a
    /// workspace by its index in the full list: a slot between two regular
    /// rows has to land between those same two workspaces there, whatever
    /// Board workspaces or herds sit between them in herdr's own order.
    func testARailSlotMapsToTheSameNeighboursInHerdrsFullOrder() {
        let full = model(["flock", "herd: review-shapes", "deck", "🛹 Reviews", "notes", "herd: acme-sweep", "🛹 Doctors"])
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 0, in: full, board: board), 0)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 1, in: full, board: board), 2)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: full, board: board), 4)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 3, in: full, board: board), 5)
    }

    func testWithNoBoardConfigBoardsDefaultNamesAreOrdinaryRows() {
        let full = model(["flock", "reviews", "deck"])
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: full, board: nil), 2)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: full, board: .defaults), 3)
    }

    func testWithNothingSetAsideARailSlotIsHerdrsOwnIndex() {
        let full = model(["flock", "deck"])
        for index in 0...2 {
            XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: index, in: full, board: board), index)
        }
    }

    /// flock's own workspaces sit in herdr's order too, and herdr appends new
    /// ones, so one soon lands between visible rows. A slot has to map past it.
    func testFlocksOwnWorkspacesAreNotRailRows() {
        let full = model(["acme", "notes", "flock:rt", "deck", "flock:rt runner term_a1"])
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: full, board: nil), 3)
        XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 3, in: full, board: nil), 4)
    }

    // MARK: - Keyboard order

    func testNavigationWalksTheRailTopToBottom() {
        let sections = RailSections(model: model(["herd: ship", "🛹 Reviews", "flock", "acme"]), board: board)
        XCTAssertEqual(sections.navigationOrder { _ in false }.map(\.title), ["flock", "acme", "🛹 Reviews", "ship"])
    }

    func testNavigationSkipsAFoldedSection() {
        let sections = RailSections(model: model(["herd: ship", "🛹 Reviews", "flock"]), board: board)
        XCTAssertEqual(sections.navigationOrder { $0 == .board }.map(\.title), ["flock", "ship"])
        XCTAssertEqual(sections.navigationOrder { $0 == .herds }.map(\.title), ["flock", "🛹 Reviews"])
    }

    // MARK: - Top bar

    func testTopBarPinsLeavePinnedAndFindTheirRecordInTheTopBarModel() {
        let full = model(["acme", "dash"])
        let hidden = full.hiding([WorkspaceID(rawValue: "w2")])
        let rail = PinnedWorkspace(id: PinID(rawValue: "p1"), name: "acme", folder: "/acme",
                                   workspace: WorkspaceID(rawValue: "w1"), syncedLabel: "acme", confirmed: true)
        let bar = PinnedWorkspace(id: PinID(rawValue: "p2"), name: "dash", folder: "/dash",
                                  workspace: WorkspaceID(rawValue: "w2"), syncedLabel: "dash", confirmed: true,
                                  placement: .topBar)
        let sections = RailSections(model: hidden, board: nil, pins: [rail, bar], topBarModel: full)
        XCTAssertEqual(sections.pinned.map(\.pin.id), [rail.id])
        XCTAssertEqual(sections.topBar.map(\.pin.id), [bar.id])
        XCTAssertEqual(sections.topBar.first?.record?.label, "dash")
    }
}
