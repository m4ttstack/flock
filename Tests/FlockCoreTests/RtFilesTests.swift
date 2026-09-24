import XCTest
@testable import FlockCore

final class RtFilesTests: XCTestCase {
    func testPathsAreNamedByToken() {
        let paths = RtFilePaths(token: "3f2a", directory: URL(fileURLWithPath: "/tmp/flock-rt", isDirectory: true))
        XCTAssertEqual(paths.out.path, "/tmp/flock-rt/3f2a.out")
        XCTAssertEqual(paths.status.path, "/tmp/flock-rt/3f2a.status")
    }

    func testASeedFileSitsBesideTheOthers() {
        let paths = RtFilePaths(token: "3f2a", directory: URL(fileURLWithPath: "/tmp/flock-rt", isDirectory: true))
        XCTAssertEqual(paths.seed.path, "/tmp/flock-rt/3f2a.seed")
    }

    func testAStatusFileReadsAsItsNumber() {
        XCTAssertEqual(RtFileParse.status("0\n"), 0)
        XCTAssertEqual(RtFileParse.status("130"), 130)
        XCTAssertNil(RtFileParse.status(""))
        XCTAssertNil(RtFileParse.status(nil))
    }

    /// `echo $? >file` creates the file before it writes the digits.
    func testABlankStatusFileIsNotYetWritten() {
        XCTAssertNil(RtFileParse.writtenStatus(""))
        XCTAssertNil(RtFileParse.writtenStatus("\n"))
        XCTAssertNil(RtFileParse.writtenStatus(nil))
        XCTAssertEqual(RtFileParse.writtenStatus("0\n"), "0\n")
    }

    /// `rt run --resolve-only` prints the result as one JSON line.
    func testARunResultReadsAsJSONAndAnythingElseAsNone() {
        let line = #"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"# + "\n"
        XCTAssertEqual(RtFileParse.runResult(line)?.commandTemplate, "pnpm run test")
        XCTAssertNil(RtFileParse.runResult(""))
        XCTAssertNil(RtFileParse.runResult("/src/acme/web\n"))
        XCTAssertNil(RtFileParse.runResult(nil))
    }

    /// A queue or preset picked under `--resolve-only` comes back as seed rows.
    func testASeedReadsOnlyAsANonEmptySeedEnvelope() {
        let seed = #"{"seed":[{"name":"dev","command":"pnpm run dev","cwd":"/src/acme/web","pkg":"web","repo":"acme"}]}"#
        XCTAssertEqual(RtFileParse.seed(seed + "\n"), seed)
        XCTAssertNil(RtFileParse.seed(#"{"seed":[]}"#))
        XCTAssertNil(RtFileParse.seed(#"{"targetDir":"/src/acme/web","packageLabel":"web","worktree":"/src/acme","branch":"main","commandTemplate":"pnpm run test","script":"test"}"#))
        XCTAssertNil(RtFileParse.seed("/src/acme\n"))
        XCTAssertNil(RtFileParse.seed(nil))
    }

    func testTheDiskStoreReadsDeletesAndMakesItsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskRtFileStore()
        store.prepareDirectory(directory)
        let url = directory.appendingPathComponent("a.status")
        store.write("0\n", to: url)

        XCTAssertEqual(store.read(url), "0\n")
        store.delete(url)
        XCTAssertNil(store.read(url))
    }
}
