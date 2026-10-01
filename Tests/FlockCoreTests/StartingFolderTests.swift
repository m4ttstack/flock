import XCTest
@testable import FlockCore

final class StartingFolderTests: XCTestCase {
    private let suiteName = "dev.mattstack.flock.starting-folder-tests"
    private let home = "/Users/acme"
    private var root: URL!

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starting-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - store

    @MainActor
    func testAFreshStoreSendsNewTabsToTheMainCheckoutAndEverythingElseWithThePane() throws {
        let store = StartingFolderStore(userDefaults: try makeDefaults())
        XCTAssertEqual(store.choice(for: .tab).folder, .mainCheckout)
        XCTAssertEqual(store.choice(for: .pane).folder, .currentPane)
        XCTAssertEqual(store.choice(for: .workspace).folder, .currentPane)
    }

    @MainActor
    func testEachKindsChoiceSurvivesTheNextLaunchOnItsOwn() throws {
        let suite = try makeDefaults()
        let store = StartingFolderStore(userDefaults: suite)
        store.select(.home, for: .pane)
        store.selectCustom(path: "/Users/acme/notes", for: .workspace)

        let reopened = StartingFolderStore(userDefaults: suite)
        XCTAssertEqual(reopened.choice(for: .pane), StartingFolderChoice(folder: .home))
        XCTAssertEqual(reopened.choice(for: .workspace), StartingFolderChoice(folder: .custom, customPath: "/Users/acme/notes"))
        XCTAssertEqual(reopened.choice(for: .tab).folder, .mainCheckout)
    }

    @MainActor
    func testLeavingCustomKeepsThePathForTheNextTimeItIsChosen() throws {
        let store = StartingFolderStore(userDefaults: try makeDefaults())
        store.selectCustom(path: "/Users/acme/notes", for: .tab)
        store.select(.home, for: .tab)
        XCTAssertEqual(store.choice(for: .tab).customPath, "/Users/acme/notes")
    }

    @MainActor
    func testAValueThisBuildDoesNotKnowOpensAtTheKindsDefault() throws {
        let suite = try makeDefaults()
        suite.set("sideways", forKey: StartingFolderStore.defaultsKey(for: .tab))
        XCTAssertEqual(StartingFolderStore(userDefaults: suite).choice(for: .tab).folder, .mainCheckout)
    }

    // MARK: - resolution

    func testCurrentPaneSendsNoFolderSoHerdrFollowsThePane() {
        XCTAssertNil(StartingFolderChoice(folder: .currentPane).cwd(paneFolder: "/Users/acme/code", home: home))
    }

    func testHomeIsHomeWhereverThePaneIs() {
        XCTAssertEqual(StartingFolderChoice(folder: .home).cwd(paneFolder: "/Users/acme/code", home: home), home)
    }

    func testMainCheckoutFollowsAWorktreeBackToItsRepo() throws {
        let repo = root.appendingPathComponent("acme")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try "../..\n".write(to: repo.appendingPathComponent(".git/worktrees/wt/commondir"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("trees/wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo.appendingPathComponent(".git/worktrees/wt").path)\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(StartingFolderChoice(folder: .mainCheckout).cwd(paneFolder: worktree.path, home: home), repo.path)
    }

    func testMainCheckoutOutsideARepoFallsBackToHome() {
        XCTAssertEqual(StartingFolderChoice(folder: .mainCheckout).cwd(paneFolder: root.path, home: home), home)
        XCTAssertEqual(StartingFolderChoice(folder: .mainCheckout).cwd(paneFolder: nil, home: home), home)
    }

    func testACustomFolderThatExistsIsUsed() {
        XCTAssertEqual(StartingFolderChoice(folder: .custom, customPath: root.path).cwd(paneFolder: nil, home: home), root.path)
    }

    func testACustomFolderThatIsGoneFallsBackToHome() {
        let gone = root.appendingPathComponent("gone").path
        XCTAssertEqual(StartingFolderChoice(folder: .custom, customPath: gone).cwd(paneFolder: nil, home: home), home)
        XCTAssertEqual(StartingFolderChoice(folder: .custom).cwd(paneFolder: nil, home: home), home)
    }

    func testOnlyMainCheckoutNeedsThePanesFolder() {
        XCTAssertEqual(StartingFolder.allCases.filter(\.needsPaneFolder), [.mainCheckout])
    }
}
