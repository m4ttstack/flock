import XCTest
@testable import FlockCore

@MainActor
final class MissionBottomLineTests: XCTestCase {
    private let own = RepoBranch(repo: "flock", branch: "mission-control")
    private let other = RepoBranch(repo: "repo-tools", branch: "main")
    private let loose = RepoBranch(repo: "notes", branch: nil)

    func testBranchDropsTheRepoNamedLikeTheWorkspace() {
        XCTAssertEqual(MissionBottomLine.branch.text(own, workspace: "Flock"), "mission-control")
        XCTAssertEqual(MissionBottomLine.branch.text(other, workspace: "boxscore"), "repo-tools @ main")
        XCTAssertEqual(MissionBottomLine.branch.text(loose, workspace: "notes"), "notes", "no branch keeps the folder's name")
    }

    func testRepoAndBranchAlwaysShowsBoth() {
        XCTAssertEqual(MissionBottomLine.repoAndBranch.text(own, workspace: "flock"), "flock @ mission-control")
        XCTAssertEqual(MissionBottomLine.repoAndBranch.text(loose, workspace: "acme"), "notes")
    }

    func testHiddenShowsNoText() {
        XCTAssertNil(MissionBottomLine.hidden.text(own, workspace: "flock"))
    }

    func testBranchUntilChosenOtherwiseAndRemembered() {
        let name = "MissionBottomLineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MissionBottomLineStore(userDefaults: defaults).active, .branch)
        MissionBottomLineStore(userDefaults: defaults).select(.hidden)
        XCTAssertEqual(MissionBottomLineStore(userDefaults: defaults).active, .hidden)
    }
}
