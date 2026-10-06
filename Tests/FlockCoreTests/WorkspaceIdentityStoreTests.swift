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

    func testNewWorkspacesTakeTheLeastUsedHueInOrder() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1", "w2", "w3"])
        XCTAssertEqual(["w1", "w2", "w3"].compactMap(store.index(for:)), [0, 1, 2])
    }

    func testAnAssignmentNeverChangesOnceMade() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w2"])
        store.assign(["w1", "w2"])
        XCTAssertEqual(store.index(for: "w2"), 0)
        XCTAssertEqual(store.index(for: "w1"), 1)
    }

    func testAnOverrideWinsAndSurvivesANewStore() {
        let defaults = defaults()
        let store = WorkspaceIdentityStore(userDefaults: defaults)
        store.assign(["w1"])
        store.setOverride(5, for: "w1")
        XCTAssertEqual(WorkspaceIdentityStore(userDefaults: defaults).index(for: "w1"), 5)
        store.setOverride(nil, for: "w1")
        XCTAssertEqual(store.index(for: "w1"), 0)
    }

    func testWorkspacesNoLongerReportedAreDroppedButTheBoardKeyStays() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign([WorkspaceIdentityStore.boardKey, "w1", "w2"])
        store.keepOnly(["w2"])
        XCTAssertNil(store.index(for: "w1"))
        XCTAssertNotNil(store.index(for: "w2"))
        XCTAssertNotNil(store.index(for: WorkspaceIdentityStore.boardKey))
    }

    func testAssignCountsOverridesWhenChoosingTheLeastUsedHue() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1"])
        store.setOverride(1, for: "w1")
        store.assign(["w2"])
        XCTAssertEqual(store.index(for: "w2"), 0)
        store.assign(["w3"])
        XCTAssertEqual(store.index(for: "w3"), 2)
    }

    func testAnOverrideOutsideThePaletteIsIgnored() {
        let store = WorkspaceIdentityStore(userDefaults: defaults())
        store.assign(["w1"])
        store.setOverride(IdentityPalette.count, for: "w1")
        store.setOverride(-1, for: "w1")
        XCTAssertEqual(store.index(for: "w1"), 0)
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
