import XCTest
@testable import FlockCore

@MainActor
final class WorkspaceIdentityStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "WorkspaceIdentityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let names = WorkspaceSymbols.all.map(\.name)

    func testNewWorkspacesTakeTheLeastUsedSymbolInOrder() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1", "w2", "w3"])
        XCTAssertEqual(["w1", "w2", "w3"].compactMap(store.symbol(for:)), Array(names.prefix(3)))
    }

    func testNeighboursDoNotRepeatUntilTheSetIsUsedUp() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        let keys = (0..<names.count).map { "w\($0)" }
        store.assign(keys)
        XCTAssertEqual(Set(keys.compactMap(store.symbol(for:))).count, names.count)
        store.assign(["extra"])
        XCTAssertEqual(store.symbol(for: "extra"), names[0])
    }

    func testAnAssignmentNeverChangesOnceMade() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w2"])
        store.assign(["w1", "w2"])
        XCTAssertEqual(store.symbol(for: "w2"), names[0])
        XCTAssertEqual(store.symbol(for: "w1"), names[1])
    }

    func testAnOverrideWinsAndSurvivesANewStore() {
        let defaults = defaults()
        let store = WorkspaceIdentityStore(userDefaults: defaults)
        store.assign(["w1"])
        store.setOverride(names[5], for: "w1")
        XCTAssertEqual(WorkspaceIdentityStore(userDefaults: defaults).symbol(for: "w1"), names[5])
        store.setOverride(nil, for: "w1")
        XCTAssertEqual(store.symbol(for: "w1"), names[0])
    }

    func testWorkspacesNoLongerReportedAreDroppedButTheBoardKeyStays() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign([WorkspaceIdentityStore.boardKey, "w1", "w2"])
        store.keepOnly(["w2"])
        XCTAssertNil(store.symbol(for: "w1"))
        XCTAssertNotNil(store.symbol(for: "w2"))
        XCTAssertNotNil(store.symbol(for: WorkspaceIdentityStore.boardKey))
    }

    func testAssignCountsOverridesWhenChoosingTheLeastUsedSymbol() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1"])
        store.setOverride(names[1], for: "w1")
        store.assign(["w2"])
        XCTAssertEqual(store.symbol(for: "w2"), names[0])
        store.assign(["w3"])
        XCTAssertEqual(store.symbol(for: "w3"), names[2])
    }

    func testAnOverrideOutsideTheSetIsIgnored() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1"])
        store.setOverride("checkmark.circle.fill", for: "w1")
        store.setOverride("", for: "w1")
        XCTAssertEqual(store.symbol(for: "w1"), names[0])
    }

    func testAStoredSymbolNoLongerInTheSetIsDroppedOnLoad() {
        let defaults = defaults()
        let stored = #"{"assigned":{"w1":"retired.fill","w2":"bolt.fill"},"overrides":{"w3":"retired.fill"}}"#
        defaults.set(Data(stored.utf8), forKey: WorkspaceIdentityStore.defaultsKey)
        let store = WorkspaceIdentityStore(userDefaults: defaults)
        XCTAssertNil(store.symbol(for: "w1"))
        XCTAssertEqual(store.symbol(for: "w2"), "bolt.fill")
        XCTAssertNil(store.symbol(for: "w3"))
    }

    func testKeysShareTheBoardsAndGiveHerdsNone() {
        let model = MissionFixture.model([
            .init(label: "acme", tabs: [.init(label: "a", panes: [.init(status: .idle)])]),
            .init(label: "Responses", tabs: [.init(label: "r", panes: [.init(status: .idle)])]),
            .init(label: "herd: sweep", tabs: [.init(label: "w", panes: [.init(status: .idle)])]),
        ])
        let sections = RailSections(model: model, board: BoardWorkspaceNames(reviews: "Reviews", responds: "Responses", doctors: "Doctors"))
        XCTAssertEqual(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w1"), sections: sections), "w1")
        XCTAssertEqual(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w2"), sections: sections), WorkspaceIdentityStore.boardKey)
        XCTAssertNil(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w3"), sections: sections))
        let railRows = ["w1", "w2", "w3"].map {
            WorkspaceIdentityStore.isRailRow(key: WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: $0), sections: sections))
        }
        XCTAssertEqual(railRows, [true, false, false], "only an ordinary workspace has the rail's menu and rename")
    }

    func testKeysInRailOrderNameTheBoardOnceAndSkipHerds() {
        let model = MissionFixture.model([
            .init(label: "Responses", tabs: [.init(label: "r", panes: [.init(status: .idle)])]),
            .init(label: "acme", tabs: [.init(label: "a", panes: [.init(status: .idle)])]),
            .init(label: "Reviews", tabs: [.init(label: "v", panes: [.init(status: .idle)])]),
            .init(label: "herd: sweep", tabs: [.init(label: "w", panes: [.init(status: .idle)])]),
        ])
        let sections = RailSections(model: model, board: BoardWorkspaceNames(reviews: "Reviews", responds: "Responses", doctors: "Doctors"))
        XCTAssertEqual(WorkspaceIdentityStore.keys(in: sections), ["w2", WorkspaceIdentityStore.boardKey])
    }
}
