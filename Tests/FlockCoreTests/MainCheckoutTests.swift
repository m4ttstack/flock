import XCTest
@testable import FlockCore

/// Every layout is built by hand, the way git leaves it on disk, so no test
/// runs git.
final class MainCheckoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("main-checkout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The repo, plus a worktree of it named `wt` living at `worktreePath`.
    private func makeRepo(withWorktreeAt worktreePath: String, gitdirLine: (URL) -> String) throws -> URL {
        let repo = try dir("acme")
        _ = try dir("acme/.git/objects")
        try write("../..\n", to: "acme/.git/worktrees/wt/commondir")
        _ = try dir(worktreePath)
        let gitDir = repo.appendingPathComponent(".git/worktrees/wt", isDirectory: true)
        try write(gitdirLine(gitDir), to: "\(worktreePath)/.git")
        return repo
    }

    func testAFolderInsideTheMainCheckoutResolvesToItsRoot() throws {
        let repo = try dir("acme")
        _ = try dir("acme/.git")
        let deep = try dir("acme/Sources/App")
        XCTAssertEqual(MainCheckout.resolve(from: deep.path), repo.path)
        XCTAssertEqual(MainCheckout.resolve(from: repo.path), repo.path)
    }

    func testALinkedWorktreeResolvesToTheMainCheckout() throws {
        let repo = try makeRepo(withWorktreeAt: "trees/wt") { "gitdir: \($0.path)\n" }
        let inside = try dir("trees/wt/Sources")
        XCTAssertEqual(MainCheckout.resolve(from: inside.path), repo.path)
    }

    func testAWorktreeNestedInsideTheRepoResolvesToTheRepoNotItself() throws {
        let repo = try makeRepo(withWorktreeAt: "acme/.claude/worktrees/wt") { "gitdir: \($0.path)\n" }
        let worktree = root.appendingPathComponent("acme/.claude/worktrees/wt")
        XCTAssertEqual(MainCheckout.resolve(from: worktree.path), repo.path)
    }

    func testARelativeGitdirIsReadFromTheWorktree() throws {
        let repo = try makeRepo(withWorktreeAt: "trees/wt") { _ in "gitdir: ../../acme/.git/worktrees/wt\n" }
        let worktree = root.appendingPathComponent("trees/wt")
        XCTAssertEqual(MainCheckout.resolve(from: worktree.path), repo.path)
    }

    /// A submodule's `.git` file points into its parent's `.git/modules`,
    /// which has no `commondir`: the submodule is its own only checkout.
    func testASubmoduleResolvesToItself() throws {
        _ = try dir("acme/.git/modules/lib")
        let lib = try dir("acme/lib")
        try write("gitdir: ../.git/modules/lib\n", to: "acme/lib/.git")
        XCTAssertEqual(MainCheckout.resolve(from: lib.path), lib.path)
    }

    func testAWorktreeOfABareRepoHasNoMainCheckout() throws {
        _ = try dir("acme.git/worktrees/wt")
        try write("../..\n", to: "acme.git/worktrees/wt/commondir")
        let worktree = try dir("trees/wt")
        try write("gitdir: \(root.appendingPathComponent("acme.git/worktrees/wt").path)\n", to: "trees/wt/.git")
        XCTAssertNil(MainCheckout.resolve(from: worktree.path))
    }

    func testAFolderOutsideAnyRepoHasNoMainCheckout() throws {
        let plain = try dir("notes/2026")
        XCTAssertNil(MainCheckout.resolve(from: plain.path))
    }

    func testAnUnreadableGitFileHasNoMainCheckout() throws {
        let odd = try dir("odd")
        try write("not a gitdir line\n", to: "odd/.git")
        XCTAssertNil(MainCheckout.resolve(from: odd.path))
    }
}
