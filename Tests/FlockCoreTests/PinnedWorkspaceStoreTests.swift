import XCTest
@testable import FlockCore

@MainActor
final class PinnedWorkspaceStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "flock-pins-\(UUID().uuidString)")!
    }

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

    private let anyRow: (WorkspaceRecord) -> Bool = { _ in true }

    func testAddingRefusesATakenNameIgnoringCaseAndSpaces() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        XCTAssertNotNil(store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil))
        XCTAssertNil(store.add(workspace: WorkspaceID(rawValue: "w2"), name: " ACME ", folder: "/acme", at: nil))
        XCTAssertNil(store.add(workspace: WorkspaceID(rawValue: "w1"), name: "other", folder: "/acme", at: nil),
                     "a workspace is pinned once")
        XCTAssertEqual(store.pins.map(\.name), ["acme"])
    }

    func testAddInsertsAtTheGivenIndexAndMoveReorders() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "b", folder: "/b", at: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w3"), name: "c", folder: "/c", at: 0)
        XCTAssertEqual(store.pins.map(\.name), ["c", "a", "b"])
        store.move(a.id, toInsertIndex: 3)
        XCTAssertEqual(store.pins.map(\.name), ["c", "b", "a"])
        store.move(a.id, toInsertIndex: 0)
        XCTAssertEqual(store.pins.map(\.name), ["a", "c", "b"])
    }

    func testPinsRoundTripThroughDefaultsAndUnreadableDataLoadsEmpty() {
        let defaults = defaults()
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins, store.pins)
        defaults.set(Data("not json".utf8), forKey: PinnedWorkspaceStore.defaultsKey)
        XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins, [])
    }

    func testAPinWhoseWorkspaceIsGoneBecomesEmpty() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([("w2", "other")]), eligible: anyRow)
        XCTAssertNil(store.pins[0].workspace)
        XCTAssertEqual(store.pins[0].name, "acme")
    }

    func testANameFollowsARenameMadeAnywhere() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([("w1", "acme web")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].name, "acme web")
    }

    func testAnEmptyPinAdoptsTheFirstUnlinkedWorkspaceWithItsNameIgnoringCase() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([]), eligible: anyRow)
        store.reconcile(with: model([("w7", "other"), ("w8", "Acme "), ("w9", "acme")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].workspace, WorkspaceID(rawValue: "w8"))
    }

    func testAdoptionSkipsWorkspacesThatAreNotRailRows() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([]), eligible: anyRow)
        store.reconcile(with: model([("w8", "acme")]), eligible: { $0.workspaceID.rawValue != "w8" })
        XCTAssertNil(store.pins[0].workspace)
    }

    func testALinkFromACreateSurvivesSnapshotsThatDoNotCarryItYet() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let pin = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)!
        store.reconcile(with: model([]), eligible: anyRow)
        store.link(pin.id, to: WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].workspace, WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([("w9", "acme")]), eligible: anyRow)
        store.reconcile(with: model([]), eligible: anyRow)
        XCTAssertNil(store.pins[0].workspace, "once herdr has shown it, its absence unlinks")
    }

    func testAFreshLinkTakesTheFirstLabelItSeesWithoutRenaming() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let pin = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)!
        store.reconcile(with: model([]), eligible: anyRow)
        store.link(pin.id, to: WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([("w9", "3")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].name, "acme")
        store.reconcile(with: model([("w9", "acme")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].name, "acme")
    }

    func testANameDoesNotFollowARenameOntoAnotherPinsName() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "b", folder: "/b", at: nil)
        store.reconcile(with: model([("w1", "B"), ("w2", "b")]), eligible: anyRow)
        XCTAssertEqual(store.pins.map(\.name), ["a", "b"])
        store.reconcile(with: model([("w1", "c"), ("w2", "b")]), eligible: anyRow)
        XCTAssertEqual(store.pins.map(\.name), ["c", "b"])
    }

    func testRenameRefusesAnotherPinsName() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "b", folder: "/b", at: nil)
        XCTAssertFalse(store.rename(a.id, to: "B"))
        XCTAssertTrue(store.rename(a.id, to: "c"))
        XCTAssertEqual(store.pins.map(\.name), ["c", "b"])
    }

    func testTheFirstPaneFolderIsItsForegroundFolderElseItsCwd() {
        var model = model([("w1", "acme")])
        XCTAssertEqual(PinFolders.firstPane(of: WorkspaceID(rawValue: "w1"), in: model), "/acme/acme")
        model.panes[PaneID(rawValue: "w1:p1")]?.foregroundCwd = "/acme/apps/web"
        XCTAssertEqual(PinFolders.firstPane(of: WorkspaceID(rawValue: "w1"), in: model), "/acme/apps/web")
        XCTAssertNil(PinFolders.firstPane(of: WorkspaceID(rawValue: "nope"), in: model))
    }
}
