import FlockCore
import Foundation
import XCTest

/// Stands in for `herdr --version` on a fixture file whose bytes start
/// `herdr X`, so store tests never run the file they write.
enum HerdrVersionFixture {
    static func read(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let words = text.split(separator: " ", maxSplits: 2)
        guard words.count >= 2, words[0] == "herdr" else { return nil }
        return "herdr \(words[1])\n"
    }
}

/// Runs throwaway shell scripts standing in for herdr, never herdr itself.
final class HerdrVersionReaderTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func script(_ body: String) throws -> String {
        let path = root.appendingPathComponent("herdr-\(UUID().uuidString)").path
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private let reader = HerdrVersionReader(deadline: 10, environment: { [:] })

    func testReturnsWhatTheBinaryPrintsForVersion() throws {
        let path = try script(#"[ "$1" = "--version" ] && echo "herdr 0.9.5""#)

        let output = reader.read(binaryPath: path)

        XCTAssertEqual(output, "herdr 0.9.5\n")
        XCTAssertEqual(output.flatMap { HerdrMousePatchVersion.parse(versionOutput: $0) }, "0.9.5")
    }

    func testANonZeroExitIsNoAnswer() throws {
        XCTAssertNil(reader.read(binaryPath: try script("echo herdr 0.9.5; exit 2")))
    }

    func testAFileThatCannotRunIsNoAnswer() throws {
        let path = root.appendingPathComponent("herdr").path
        try Data("herdr 0.9.5 not an executable".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertNil(reader.read(binaryPath: path))
    }

    func testARunPastTheDeadlineIsStoppedAndIsNoAnswer() throws {
        let path = try script("sleep 30")
        let start = Date()

        XCTAssertNil(HerdrVersionReader(deadline: 0.2, environment: { [:] }).read(binaryPath: path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
