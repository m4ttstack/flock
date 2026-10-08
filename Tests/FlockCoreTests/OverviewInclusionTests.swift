import XCTest
@testable import FlockCore

@MainActor
final class OverviewInclusionTests: XCTestCase {
    private let board = BoardWorkspaceNames(reviews: "🛹 Reviews", responds: "🛹 Responses", doctors: "🛹 Doctors")

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

    func testBothIncludedUntilTurnedOffAndRemembered() {
        let name = "OverviewInclusionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OverviewInclusionStore(userDefaults: defaults)
        XCTAssertTrue(store.includesReviews)
        XCTAssertTrue(store.includesHerds)
        store.setIncludesHerds(false)
        let again = OverviewInclusionStore(userDefaults: defaults)
        XCTAssertTrue(again.includesReviews)
        XCTAssertFalse(again.includesHerds)
    }

    func testOnlyWhatIsTurnedOffIsLeftOut() {
        let name = "OverviewInclusionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OverviewInclusionStore(userDefaults: defaults)
        let sections = RailSections(model: model(["flock", "🛹 Reviews", "herd: acme-batch"]), board: board)
        XCTAssertEqual(store.excluded(from: sections), [])
        store.setIncludesReviews(false)
        XCTAssertEqual(store.excluded(from: sections), [WorkspaceID(rawValue: "w2")])
        store.setIncludesHerds(false)
        XCTAssertEqual(store.excluded(from: sections), [WorkspaceID(rawValue: "w2"), WorkspaceID(rawValue: "w3")])
    }

    func testAModelWithoutWorkspacesDropsTheirPanesAndFocus() {
        var full = model(["flock", "🛹 Reviews"])
        full.focusedWorkspaceID = WorkspaceID(rawValue: "w2")
        let narrowed = full.without(workspaces: [WorkspaceID(rawValue: "w2")])
        XCTAssertEqual(narrowed.workspaces.map(\.label), ["flock"])
        XCTAssertNil(narrowed.focusedWorkspaceID)
        XCTAssertEqual(full.without(workspaces: []), full)
    }
}
