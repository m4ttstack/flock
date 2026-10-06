import XCTest
@testable import FlockCore

final class RepoBranchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testHeadParsing() {
        XCTAssertEqual(RepoBranchReader.branch(head: "ref: refs/heads/mr-badge\n"), "mr-badge")
        XCTAssertEqual(RepoBranchReader.branch(head: "ref: refs/heads/herd/auth-2"), "herd/auth-2")
        XCTAssertEqual(RepoBranchReader.branch(head: "3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39\n"), "3f2a9c1")
        XCTAssertNil(RepoBranchReader.branch(head: "garbage"))
    }

    func testAMainCheckoutNamesItsFolderAndBranch() throws {
        try write("ref: refs/heads/main\n", to: "acme-api/.git/HEAD")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("acme-api/src"), withIntermediateDirectories: true)
        let read = RepoBranchReader.read(folder: root.appendingPathComponent("acme-api/src").path)
        XCTAssertEqual(read, RepoBranch(repo: "acme-api", branch: "main"))
        XCTAssertEqual(read.text, "acme-api @ main")
    }

    func testALinkedWorktreeNamesTheMainCheckoutAndItsOwnBranch() throws {
        try write("ref: refs/heads/main\n", to: "acme-api/.git/HEAD")
        try write("ref: refs/heads/refunds\n", to: "acme-api/.git/worktrees/refunds/HEAD")
        try write("../..\n", to: "acme-api/.git/worktrees/refunds/commondir")
        let tree = root.appendingPathComponent("trees/refunds")
        try write("gitdir: \(root.appendingPathComponent("acme-api/.git/worktrees/refunds").path)\n", to: "trees/refunds/.git")
        XCTAssertEqual(RepoBranchReader.read(folder: tree.path), RepoBranch(repo: "acme-api", branch: "refunds"))
    }

    func testAFolderOutsideAnyRepositoryIsItsOwnNameAlone() throws {
        let plain = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let read = RepoBranchReader.read(folder: plain.path)
        XCTAssertEqual(read, RepoBranch(repo: "notes", branch: nil))
        XCTAssertEqual(read.text, "notes")
    }

    @MainActor
    func testTheCacheReadsAFolderOnceUntilInvalidated() {
        var reads = 0
        let cache = RepoBranchCache { folder in reads += 1; return RepoBranch(repo: folder, branch: nil) }
        _ = cache.repoBranch(for: "/a")
        _ = cache.repoBranch(for: "/a")
        XCTAssertEqual(reads, 1)
        cache.invalidate()
        _ = cache.repoBranch(for: "/a")
        XCTAssertEqual(reads, 2)
    }
}
