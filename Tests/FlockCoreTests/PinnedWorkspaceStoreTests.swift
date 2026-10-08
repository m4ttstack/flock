import XCTest
@testable import FlockCore

@MainActor
final class PinnedWorkspaceStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "flock-pins-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
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
        store.reconcile(with: model([]), reopening: [pin.id], eligible: anyRow)
        XCTAssertEqual(store.pins[0].workspace, WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([("w9", "acme")]), reopening: [pin.id], eligible: anyRow)
        store.reconcile(with: model([]), reopening: [pin.id], eligible: anyRow)
        XCTAssertNil(store.pins[0].workspace, "once herdr has shown it, its absence unlinks")
    }

    /// The workspace closed, or herdr went away, between the create and the
    /// first snapshot that would have carried it.
    func testALinkHerdrNeverReportedIsDroppedOnceTheReopenIsOver() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let pin = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)!
        store.reconcile(with: model([]), eligible: anyRow)
        store.link(pin.id, to: WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([]), reopening: [pin.id], eligible: anyRow)
        XCTAssertEqual(store.pins[0].workspace, WorkspaceID(rawValue: "w9"), "kept while the reopen is out")
        store.reconcile(with: model([]), eligible: anyRow)
        XCTAssertNil(store.pins[0].workspace)
        XCTAssertFalse(store.pins[0].confirmed)
    }

    /// herdr labels a new workspace after its folder, and its created event
    /// can land before the create's reply. A pin of that name adopts it from
    /// the event; the reply's id then takes it back for the pin that reopened.
    func testAReopenLinksByTheReturnedIdWhileASameNamedWorkspaceExists() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let review = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme review", folder: "/acme", at: nil)!
        let acme = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "acme", folder: "/acme", at: nil)!
        store.reconcile(with: model([]), eligible: anyRow)

        store.reconcile(with: model([("w9", "acme")]), reopening: [review.id], eligible: anyRow)
        XCTAssertEqual(store.pin(acme.id)?.workspace, WorkspaceID(rawValue: "w9"), "the premise: the event beat the reply")
        store.link(review.id, to: WorkspaceID(rawValue: "w9"))
        XCTAssertEqual(store.pin(review.id)?.workspace, WorkspaceID(rawValue: "w9"))
        XCTAssertNil(store.pin(acme.id)?.workspace, "one workspace, one pin")

        store.reconcile(with: model([("w9", "acme")]), reopening: [review.id], eligible: anyRow)
        store.reconcile(with: model([("w9", "acme review")]), eligible: anyRow)
        XCTAssertEqual(store.pins.map(\.name), ["acme review", "acme"])
        XCTAssertEqual(store.pins.map(\.workspace), [WorkspaceID(rawValue: "w9"), nil])
    }

    /// A stored link that was never confirmed is an id herdr issued; it loads
    /// like any other link rather than surviving every snapshot without it.
    func testAStoredUnconfirmedLinkLoadsAsAnOrdinaryLink() throws {
        let defaults = defaults()
        let blob = #"{"version":1,"pins":[{"id":"p1","name":"acme","folder":"/acme","workspace":"w1","confirmed":false}]}"#
        defaults.set(Data(blob.utf8), forKey: PinnedWorkspaceStore.defaultsKey)
        let kept = PinnedWorkspaceStore(userDefaults: defaults)
        XCTAssertEqual(kept.pins.map(\.workspace), [WorkspaceID(rawValue: "w1")])
        kept.reconcile(with: model([("w1", "acme")]), eligible: anyRow)
        XCTAssertEqual(kept.pins.map(\.workspace), [WorkspaceID(rawValue: "w1")], "herdr still reports it")

        defaults.set(Data(blob.utf8), forKey: PinnedWorkspaceStore.defaultsKey)
        let gone = PinnedWorkspaceStore(userDefaults: defaults)
        gone.reconcile(with: model([]), eligible: anyRow)
        XCTAssertEqual(gone.pins.map(\.workspace), [nil], "herdr no longer reports it")
    }

    /// Pins written by a newer build, or unreadable, load as none and are
    /// left in place until the person changes the pins, which is the one
    /// change allowed to write over them.
    func testStoredPinsThisBuildCannotReadAreKeptUntilThePinsChange() throws {
        let newer = Data(#"{"version":2,"pins":[{"id":"p1","name":"acme","folder":"/acme","confirmed":true}],"tags":[]}"#.utf8)
        for blob in [newer, Data("not json".utf8)] {
            let defaults = defaults()
            defaults.set(blob, forKey: PinnedWorkspaceStore.defaultsKey)
            let store = PinnedWorkspaceStore(userDefaults: defaults)
            XCTAssertEqual(store.pins, [])
            store.reconcile(with: model([("w1", "acme")]), eligible: anyRow)
            XCTAssertEqual(defaults.data(forKey: PinnedWorkspaceStore.defaultsKey), blob, "running alone writes nothing")

            _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
            XCTAssertNotEqual(defaults.data(forKey: PinnedWorkspaceStore.defaultsKey), blob)
            XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins.map(\.name), ["acme"], "pinning writes over it")
        }
    }

    func testTheUnreadableBlobIsCopiedOnceBeforeThePersonsFirstChangeWritesOverIt() {
        let blob = Data("not json".utf8)
        let defaults = defaults()
        defaults.set(blob, forKey: PinnedWorkspaceStore.defaultsKey)
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        store.reconcile(with: model([("w1", "acme")]), eligible: anyRow)
        XCTAssertNil(defaults.data(forKey: PinnedWorkspaceStore.unreadableKey), "running alone copies nothing")

        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        XCTAssertEqual(defaults.data(forKey: PinnedWorkspaceStore.unreadableKey), blob)

        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "beta", folder: "/beta", at: nil)
        XCTAssertEqual(defaults.data(forKey: PinnedWorkspaceStore.unreadableKey), blob, "later saves leave the backup alone")
    }

    func testReadablePinsAreNeverCopiedToTheUnreadableKey() {
        let defaults = defaults()
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        XCTAssertNil(defaults.data(forKey: PinnedWorkspaceStore.unreadableKey))
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

    func testAStoredPinWithoutAPlacementDecodesAsRail() throws {
        let json = #"{"version":1,"pins":[{"id":"p1","name":"acme","folder":"/acme","confirmed":true}]}"#
        let defaults = defaults()
        defaults.set(Data(json.utf8), forKey: PinnedWorkspaceStore.defaultsKey)
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        XCTAssertEqual(store.pins.map(\.placement), [.rail])
    }

    func testPlacementRoundTripsThroughDefaults() {
        let defaults = defaults()
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        store.setPlacement(a.id, to: .topBar, at: nil)
        XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins.map(\.placement), [.topBar])
    }

    /// The rail draws only rail pins, so its drop index must not count a
    /// top-bar pin that sits between them in the stored order.
    func testIndicesCountOnlyThePlacementBeingDrawn() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        let t = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "t", folder: "/t", at: nil, placement: .topBar)!
        let b = store.add(workspace: WorkspaceID(rawValue: "w3"), name: "b", folder: "/b", at: nil)!
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["a", "b"])
        XCTAssertEqual(store.pins(in: .topBar).map(\.name), ["t"])
        store.move(b.id, toInsertIndex: 0)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["b", "a"])
        store.move(b.id, toInsertIndex: 2)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["a", "b"])
        store.setPlacement(a.id, to: .topBar, at: 0)
        XCTAssertEqual(store.pins(in: .topBar).map(\.name), ["a", "t"])
        store.setPlacement(t.id, to: .rail, at: 0)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["t", "b"])
        XCTAssertEqual(store.pins(in: .topBar).map(\.name), ["a"])
    }

    func testAddAtAnIndexCountsItsOwnPlacement() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "t", folder: "/t", at: nil, placement: .topBar)
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "a", folder: "/a", at: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w3"), name: "b", folder: "/b", at: 0)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["b", "a"])
    }
}
