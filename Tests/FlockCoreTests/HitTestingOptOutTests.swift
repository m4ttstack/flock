import XCTest

/// `allowsHitTesting` only ever subtracts. A view whose ancestor passed
/// `false` is out of hit testing for good, and passing `true` below it puts
/// nothing back -- so a literal `true` is either a no-op or, as it was on the
/// launcher's button row, a fix that reads as one and is not. Turn it off on
/// the drawn elements that must not answer the pointer instead of on a
/// container around them.
final class HitTestingOptOutTests: XCTestCase {
    func testNoViewTriesToOptBackIntoHitTesting() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        let swiftFiles = try Self.swiftFiles(under: sources)
        XCTAssertGreaterThan(swiftFiles.count, 50, "found almost no sources under \(sources.path); the scan resolved the wrong directory")

        var offenders: [String] = []
        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            guard contents.contains("allowsHitTesting(true)") else { continue }
            offenders.append(file.lastPathComponent)
        }
        XCTAssertEqual(offenders, [], "allowsHitTesting(true) cannot re-enable a subtree an ancestor disabled")
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "cannot read \(directory.path)"
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
